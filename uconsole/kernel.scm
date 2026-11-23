;;; uconsole/kernel.scm — the uConsole board layer over the platform kernel.
;;;
;;; What this file owns: the uConsole's patches, and the .config lines its
;;; hardware needs. What it does not own: the source pin, the defconfig per SoC,
;;; the page-size and module-compression machinery, the build phases and the
;;; install step — (rpi kernel) has all of that, so this layer cannot drift from
;;; the platform's kernel or grow a second copy of the build.
;;;
;;; The four exported package names are an interface, not a choice: uconsole's
;;; system module, uconsole/image, and configurations outside this repository
;;; select them by name, and the localversion strings are what /lib/modules on a
;;; running board is called. Renaming one breaks a boot, silently.
;;;
;;; Build:
;;;   guix build --system=aarch64-linux -L . -e '(@ (uconsole kernel) linux-uconsole-4k-zstd)'

(define-module (uconsole kernel)
  #:use-module (guix gexp)               ;local-file, for the patch files
  #:use-module (rpi kernel)
  #:export (make-linux-uconsole
            linux-uconsole
            linux-uconsole-4k
            linux-uconsole-4k-zstd
            linux-uconsole-4k-zstd-console))

;; ====================================================================
;; The board's patches
;; ====================================================================
;; Every patch here is the uConsole's own: none of them is useful on a bare
;; CM5, and the platform adds none of its own. Grouped by what they touch, so a
;; reader adding a patch can see the neighbourhood it belongs to.
;;
;; 0001 is not a driver patch and stays anyway: it enables the board's symbols
;; in bcm2711_defconfig and bcm2712_defconfig. Dropping it does not merely
;; change n, it changes .config — the power key (INPUT_AXP20X_PEK) and the ADC
;; (AXP20X_ADC) are selected by nothing else, so olddefconfig would drop them
;; and the board would boot with a dead power button.
(define %uconsole-patches
  (list
   ;; defconfig: the board's symbols, so olddefconfig keeps them
   (local-file "boot/patches/0001-configs.patch")
   ;; panel: CWU50 DSI driver, Kconfig and Makefile entries
   (local-file "boot/patches/0002-panel.patch")
   ;; power: AXP228 AC and battery paths
   (local-file "boot/patches/0003-power.patch")
   ;; backlight: OCP8178 Kconfig, Makefile and driver
   (local-file "boot/patches/0004-backlight.patch")
   ;; device tree: the clockworkpi overlays config.txt names
   (local-file "boot/patches/0005-overlays.patch")
   ;; audio: the staging amplifier path this carrier wires up
   (local-file "boot/patches/0006-bcm2835-staging.patch")
   (local-file "boot/patches/0007-simple-switch.patch")
   ;; panel fixes, applied on top of 0002
   (local-file "boot/patches/0008-panel-cwu50-dcs-detect.patch")
   (local-file "boot/patches/0009-panel-cwu50-page-select.patch")
   (local-file "boot/patches/0010-panel-cwu50-dsi-init0.patch")
   (local-file "boot/patches/0011-panel-cwu50-dsi-mode-flags.patch")))

;; ====================================================================
;; The board's .config lines
;; ====================================================================
;; THE SEQUENCE IS A CONTRACT. A deployed board's .config is compared line by
;; line against the reference build, so the full list is written out here in the
;; order the single-repository kernel produced it — three board lines, then the
;; platform-generic block with the AXP20X power symbols in the middle, then the
;; two USB lines — instead of being reassembled from (rpi kernel)'s
;; %generic-kconfig. The duplication is deliberate: a platform change has to be
;; re-checked against this list, not silently reorder a board's configuration.
;;
;; The page-size lines are NOT here: the platform derives them from #:page-size
;; and emits them before this list. The compression lines are still the last
;; block the platform writes, so their content and their place after the board's
;; lines are unchanged. The one difference in the written sequence is that the
;; console gadget lines now sit before the compression lines instead of after;
;; the two sets share no symbol, and `conf' writes .config by walking Kconfig
;; (not by echoing the appended lines back), so the file that comes out is
;; identical line for line.
(define %uconsole-kconfig
  '("CONFIG_DRM_PANEL_CWU50=y"
    "CONFIG_BACKLIGHT_OCP8178=y"
    "CONFIG_AXP228_POWER=y"
    "CONFIG_INPUT_UINPUT=y"
    "CONFIG_DRM=y"
    "CONFIG_DRM_VC4=y"
    "CONFIG_DRM_VC4_HDMI_CEC=n"
    "CONFIG_SND_SOC=y"
    "CONFIG_SND_SOC_PWM=y"
    "CONFIG_BRCMFMAC=y"
    "CONFIG_I2C_BCM2708=y"
    "CONFIG_SPI_BCM2835=y"
    "CONFIG_MFD_AXP20X=y"
    "CONFIG_MFD_AXP20X_I2C=y"
    "CONFIG_REGULATOR_AXP20X=y"
    "CONFIG_CHARGER_AXP20X=m"
    "CONFIG_BATTERY_AXP20X=m"
    ;; USB serial (CDC-ACM), built in: defconfig carries no CONFIG_USB_ACM line
    ;; at all, and a minimal module tree without modules.dep cannot autoload the
    ;; driver, so a CDC device (an Arduino, a radio's USB port, a GPS puck)
    ;; would simply never appear as /dev/ttyACM0.
    "CONFIG_USB_ACM=y"
    ;; USB audio, built in for the same reason: defconfig has it modular, and
    ;; with no modprobe at the point it is needed a USB sound card stays mute.
    "CONFIG_SND_USB_AUDIO=y"))

;; ====================================================================
;; SoM choice
;; ====================================================================
;; The panel is the same on both carriers; the SoC is not, and page size is a
;; property of the SoC, so the choice of SoM picks the defconfig and the page
;; size together. BCM2711 has no 16K-page option in Kconfig at all, which is why
;; the CM4 default is 4K rather than something to be fixed later.
(define %som-properties
  '((cm5 bcm2712 16384)
    (cm4 bcm2711 4096)))

;; ====================================================================
;; Constructor
;; ====================================================================
(define* (make-linux-uconsole #:key
                              (som 'cm5)
                              (page-size #f)
                              (localversion "-uconsole")
                              (name "linux-uconsole")
                              (module-compress "xz")
                              (extra-kconfig '()))
  (let* ((properties (or (assq som %som-properties)
                         (error "unknown SoM; expected cm4 or cm5" som)))
         (board (cadr properties))
         (page-size (or page-size (caddr properties))))
    ;; The firmware names the image after the page size, and a 16K build on
    ;; bcm2711 has no Kconfig choice behind it: fail here rather than let
    ;; olddefconfig pick something and produce a kernel that does not boot.
    (when (and (eq? board 'bcm2711) (not (= page-size 4096)))
      (error "bcm2711 only supports 4096-byte pages" name page-size))
    (make-linux-rpi
     #:board board
     #:page-size page-size
     #:localversion localversion
     #:name name
     #:module-compress module-compress
     #:patches %uconsole-patches
     #:kconfig (append %uconsole-kconfig extra-kconfig)
     #:synopsis "Linux kernel for the ClockworkPi uConsole"
     #:description
     (string-append
      "Linux kernel for the ClockworkPi uConsole, built from the Raspberry Pi\n"
      "downstream kernel for a " (symbol->string som) " SoM. It adds the CWU50\n"
      "DSI panel driver, the AXP228 power paths, the OCP8178 backlight, the\n"
      "clockworkpi device-tree overlays, and the panel fixes that make the\n"
      "display come up on this carrier."))))

;; ====================================================================
;; Exported variants
;; ====================================================================
;; 16K pages, xz modules: the CM5 default. The firmware only accepts it when the
;; image on the boot partition is named kernel_2712.img.
(define-public linux-uconsole (make-linux-uconsole))

;; 4K pages on the same CM5: what the board actually runs, because the 16K
;; kernel does not come up on this carrier. Loaded as kernel8.img.
(define-public linux-uconsole-4k
  (make-linux-uconsole #:page-size 4096
                       #:localversion "-uconsole4k"
                       #:name "linux-uconsole-4k"))

;; 4K pages, ZSTD modules: guix's initrd machinery reads .gz and .ko.zst only, so
;; this is the only variant whose drivers can be listed in initrd-modules — and
;; the panel is this board's only console, so it has to be up from early boot.
(define-public linux-uconsole-4k-zstd
  (make-linux-uconsole #:page-size 4096
                       #:localversion "-uconsole4k-zstd"
                       #:name "linux-uconsole-4k-zstd"
                       #:module-compress "zstd"))

;; Same, plus the USB gadget serial compiled in: this carrier has no HDMI and no
;; broken-out UART, so `console=ttyGS0,115200' on the USB-C port is the only way
;; to see a kernel log before the initramfs exists. Pair it with
;; `dtoverlay=dwc2,dr_mode=peripheral' in config.txt.
(define-public linux-uconsole-4k-zstd-console
  (make-linux-uconsole #:page-size 4096
                       #:localversion "-uconsole4k-zstd-console"
                       #:name "linux-uconsole-4k-zstd-console"
                       #:module-compress "zstd"
                       #:extra-kconfig %console-gadget-kconfig))

;; Return the 16K package as the file's value so `guix build -f
;; uconsole/kernel.scm` keeps working.
linux-uconsole
