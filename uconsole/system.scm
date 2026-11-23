;;; uconsole/system.scm — the bare-bones Guix System for the ClockworkPi
;;; uConsole CM5 (eMMC).
;;;
;;; What this file is: a system that BOOTS and gives you a login prompt on the
;;; panel, over ssh, and on the WiFi. Nothing else. No desktop, no editor, no
;;; radio tools — those are yours to add; this file is the base they sit on.
;;;
;;; What is NOT optional, and why (each item is a real failure mode):
;;;   - the patched kernel below: no mainline config brings this panel up;
;;;   - initrd-modules: the panel and its regulators are modules, and the panel
;;;     is this board's ONLY console (no HDMI, no broken-out UART);
;;;   - the zstd module compression: guix's initrd machinery cannot read .ko.xz,
;;;     so with any non-empty initrd-modules the xz kernel fails to build;
;;;   - the two file-system labels: guix's initrd resolves bare labels, never
;;;     LABEL=...;
;;;
;;; Build (from the repository root, after fetching the channel's dependencies):
;;;   guix system build --system=aarch64-linux -L . uconsole/system.scm --dry-run
;;; The image that carries it is uconsole/image, which imports this module.
;;;
;;; It is a MODULE, not a loose script: a channel's files are compiled when the
;;; channel is fetched, and a file under the module root without define-module
;;; fails there with "no code for module (uconsole system)" — before anyone tries
;;; to build it. The system is a named binding (uconsole-system) so the image
;;; module can import it; the file's value is the system itself, so
;;; `guix system build uconsole/system.scm' keeps working.

(define-module (uconsole system)
  #:use-module (gnu)
  #:use-module (gnu system file-systems)
  #:use-module (gnu bootloader)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services ssh)
  #:use-module (gnu services networking)
  #:use-module (gnu services desktop)     ;elogind-service-type
  #:use-module (gnu services shepherd)    ;the modprobe service
  #:use-module (gnu packages)
  #:use-module (gnu packages firmware)    ;(kept: firmware helpers)
  #:use-module (gnu packages bash)        ;the modprobe service runs bash
  #:use-module (gnu packages linux)       ;kmod (modprobe), by absolute path
  #:use-module (nongnu packages linux)    ;linux-firmware (brcmfmac ships .zst)
  #:use-module (guix gexp)                ;local-file, plain-file
  #:use-module (uconsole kernel)
  #:use-module (rpi bootloader)           ;%direct-kernel-bootloader
  #:use-module (rpi firmware))

;;; ------------------------------------------------------------------
;;; Peripheral drivers that are not in the initrd
;;; ------------------------------------------------------------------
;; The kernel ships its peripherals as modules. The initrd carries the display
;; chain (this board's only console); the rest is loaded here, after udev,
;; because a missing peripheral does not announce itself: no keys, no audio, no
;; radio, and the boot still looks successful.
(define %uconsole-device-modules
  (list "drm-rp1-dsi" "vc4" "panel-cwu50"
        "ocp8178_bl"
        "axp20x-battery" "axp20x-usb-power"
        "axp20x-ac-power" "axp20x-adc"
        "brcmfmac" "rtc-pcf85063a"
        "matrix-keymap" "gpio-keys"
        "snd-soc-upisnd-ctrl" "snd-soc-upisnd-codec"))

;; The check is on /sys/module/<name> AFTER modprobe, never on modprobe's exit
;; code alone: modprobe answers 0 for an already-loaded module and 1 for one it
;; cannot find, and this runs at a point in boot where every call can answer 1
;; while the initrd has in fact loaded the drivers — which produced a shepherd
;; failure that meant nothing, on every boot.
;;
;; The script is spliced in as TEXT: a (plain-file …) is mode 0444, so handing
;; bash that path fails with "Permission denied" for a reason unrelated to
;; drivers.
(define (uconsole-device-modules-script)
  (string-append
   "missing=''\n"
   "for m in "
   (apply string-append (map (lambda (m) (string-append m " ")) %uconsole-device-modules))
   "\ndo\n"
   "  o=$(modprobe \"$m\" 2>&1); rc=$?\n"
   "  echo \"uconsole-modprobe: $m -> $rc $o\"\n"
   "  u=$(echo \"$m\" | tr '-' '_')\n"
   "  [ -d \"/sys/module/$u\" ] || missing=\"$missing $m\"\n"
   "done\n"
   "if [ -n \"$missing\" ]; then\n"
   "  echo \"uconsole-device-modules: ABSENT from the kernel:$missing\"\n"
   "  exit 1\n"
   "fi\n"
   "echo 'uconsole-device-modules: every driver present'\n"))

(define (uconsole-device-modules-service)
  (simple-service 'uconsole-device-modules shepherd-root-service-type
   (list (shepherd-service
          (provision '(uconsole-device-modules))
          ;; user-processes, not only udev: the module tree is not reachable
          ;; before it, and the service then reports failures it cannot see.
          (requirement '(udev user-processes))
          (start #~(lambda ()
                     (zero? (status:exit-val
                             (system* #$(file-append bash "/bin/bash") "-c"
                                      (string-append
                                       "MODPROBE="
                                       #$(file-append kmod "/sbin/modprobe")
                                       "\nmodprobe() { \"$MODPROBE\" \"$@\"; }\n"
                                       #$(uconsole-device-modules-script)))))))
          (stop #~(lambda (_) #f))
          (respawn? #f)))))

(define-public uconsole-system
 (operating-system
  (host-name "uConsole")
  (timezone "Etc/UTC")
  (locale "en_US.utf8")

  ;; The kernel is the whole point of this port: 6.12.47 downstream with 11
  ;; patches (CWU50/JD9365 DSI panel, AXP228 PMU, OCP8178 backlight, I2C
  ;; keyboard, DSI mode flags), 4K pages, ZSTD modules.
  ;;
  ;; 4K and not 16K: REX and nixos-uconsole both run 4K on this CM5, and every
  ;; image that has ever lit this panel was 4K.
  ;; -zstd and not -xz: see the header — .ko.xz cannot be listed at all.
  ;; -console: compiles the USB gadget serial in, so the kernel log is readable
  ;; on the USB-C port (there is no other console before userspace). Drop the
  ;; suffix for a smaller release kernel; nothing else changes.
  (kernel linux-uconsole-4k-zstd-console)

  ;; The display chain, in the initrd, so the panel is a console from early
  ;; boot. The ROOT does not depend on any of these: the eMMC controller
  ;; (sdhci-brcmstb) and ext4 are built into this kernel. i2c-gpio IS
  ;; load-bearing for the display: the panel's AXP228 regulators sit on a
  ;; bit-banged bus declared by the clockworkpi overlay.
  (initrd-modules (list
                        ;; guix's own check demands a module for the root device
                        ;; (/dev/mmcblk0p2): a UIO platform alias matches it. The
                        ;; module exists in this kernel, so list it instead of
                        ;; silencing the check. Verified on hardware.
                        "uio_pdrv_genirq"
                        "sdhci-of-dwcmshc"
                        "i2c-gpio"
                        "axp20x_adc"
                        "axp20x_battery"
                        "axp20x_ac_power"
                        "axp20x_usb_power"
                        "rp1-fw"
                        "rp1-mailbox"
                        "vc4"
                        "drm-rp1-dsi"
                        "panel-cwu50"
                        "ocp8178_bl"
                        "backlight"
                        "i2c-bcm2835"
                        "pwm-bcm2835"
                        "drm_dma_helper"
                        "drm_shmem_helper"))

  ;; NO kernel-arguments field, on purpose: the cmdline has ONE owner, the
  ;; platform's boot writer (rpi-boot-populate), which writes cmdline.txt on the
  ;; FAT (root label, consoles, gnu.system/gnu.load). A list here is a second
  ;; copy that silently disagrees with that writer, and nothing on this board
  ;; reads a bootloader's arguments anyway — the CM5 EEPROM reads config.txt and
  ;; cmdline.txt.

  ;; Firmware, all four pieces declaratively:
  ;;   linux-firmware            the base set (brcmfmac ships .bin.zst)
  ;;   rpi-brcm43455-firmware    decompressed 43455 (this kernel has no zstd
  ;;                             firmware loader, so the .zst name is never tried
  ;;                             and WiFi dies with "brcm_sdio_htclk: HT Avail
  ;;                             timeout")
  ;;   rpi-bt-firmware           BCM4345C0.hcd — linux-firmware ships none for
  ;;                             the 4345, and without it hci_uart_bcm finds no
  ;;                             patch file and the radio never comes up
  ;;   rpi-regdb-firmware        regulatory.db(.p7s) — also absent from
  ;;                             linux-firmware here; without it the wireless
  ;;                             stack runs unregulated and 5 GHz is restricted
  (firmware (list linux-firmware
                  rpi-brcm43455-firmware
                  rpi-bt-firmware
                  rpi-regdb-firmware))

  ;; Direct-kernel boot: the CM5 firmware reads config.txt/cmdline.txt off the
  ;; FAT and loads kernel8.img itself (see docs/boot-chain.org), so this system
  ;; has no bootloader. The record Guix requires is the platform's no-op — no
  ;; package, no installer, no configuration file, no menu entries — so
  ;; `guix system reconfigure' writes nothing under /boot and cannot leave an
  ;; extlinux.conf for the firmware to ignore.
  (bootloader (bootloader-configuration
               (bootloader %direct-kernel-bootloader)
               (targets '("/dev/mmcblk0"))))

  (file-systems
   (append
    (list (file-system
           (device (file-system-label "guix-root"))
           (mount-point "/")
           (type "ext4"))
          (file-system
           (device (file-system-label "guix-boot"))
           (mount-point "/boot")
           (type "vfat")))
    %base-file-systems))

  (users (cons* (user-account
                 (name "ucon")
                 (comment "uConsole user")
                 (group "users")
                 (supplementary-groups '("wheel" "video" "audio"
                                         "render" "netdev" "dialout"))
                 (home-directory "/home/ucon"))
                %base-user-accounts))

  (groups (cons* (user-group (name "ucon"))
                 (user-group (name "render"))
                 %base-groups))

  (sudoers-file
   (plain-file "sudoers"
               "root ALL=(ALL) ALL
%wheel ALL=(ALL) ALL
"))

  ;; %base-packages is the console toolchain: bash, coreutils, grep, sed, tar…
  ;; Add what you actually use; every package here is one more thing to
  ;; substitute or compile.
  ;; glibc-locales is not decoration: without it the declared locale does not
  ;; exist, and every guix command prints the TZDIR/GUIX_LOCPATH hint.
  (packages
   (append (specifications->packages
            (list "glibc-locales"
                  "sudo" "kmod" "dosfstools" "parted"))
           %base-packages))

  (services
   (append
    (list
     ;; elogind: login sessions, and the uaccess ACLs the backlight rule needs.
     (service elogind-service-type)

     (service openssh-service-type
              (openssh-configuration
               ;; password login ON: a fresh board has no authorized_keys yet,
               ;; and the panel keyboard is the only other way in.
               (password-authentication? #t)))

     (service network-manager-service-type)
     ;; NetworkManager refuses to start without a wireless daemon: it provides
     ;; the 'wireless-daemon' requirement. wpa_supplicant, not iwd: the brcmfmac
     ;; radio on this board works with it and it needs no extra wpa config for
     ;; NetworkManager's own D-Bus API.
     (service wpa-supplicant-service-type)

     ;; Time. This board has no RTC battery, so the clock starts at the epoch on
     ;; every power-on: HTTPS, guix signatures and logs all depend on it.
     (service ntp-service-type)

     ;; /sys/class/backlight/*/brightness is root-only by default and Guix ships
     ;; no setuid brightness helper. TAG+="uaccess" gives the active seat's user
     ;; an ACL on it, which is what brightnessctl (and any bar module) needs.
     (udev-rules-service 'backlight-uaccess
       (file->udev-rule "90-backlight-uaccess.rules"
                        (plain-file "90-backlight-uaccess.rules"
                                    "SUBSYSTEM==\"backlight\", TAG+=\"uaccess\", MODE=\"0664\"\n")))

     ;; Load the peripheral drivers this board needs after udev (see
     ;; %uconsole-device-modules above).
     (uconsole-device-modules-service))
    (modify-services %base-services
      ;; bordeaux is the only substitute server with a reliable aarch64 closure
      ;; (ci.guix hangs builds, bayfront is gone). Your own `guix publish' cache
      ;; goes here too, authorized — the public servers carry no custom kernel.
      (guix-service-type config =>
        (guix-configuration
         (inherit config)
         (substitute-urls '("https://bordeaux.guix.gnu.org"))
         (authorized-keys %default-authorized-guix-keys)
         ;; OPTIONAL: --max-jobs=0 turns "this package has no substitute" into an
         ;; immediate hard failure instead of hours of emulated compilation on a
         ;; handheld. Convenient on a slow board, inconvenient while debugging a
         ;; package, hence commented out:
         ;; (extra-options '("--max-jobs=0"))
         )))))))

;; The value of the file, for `guix system build uconsole/system.scm' and for
;; anyone loading it with `load'; the name above is what uconsole/image imports.
uconsole-system
