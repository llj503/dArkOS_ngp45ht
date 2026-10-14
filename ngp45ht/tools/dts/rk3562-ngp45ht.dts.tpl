// SPDX-License-Identifier: (GPL-2.0+ OR MIT)
/*
 * dArkOS for the NGP45HT — Rockchip RK3562 handheld
 *
 * Same SoC, same RK3562 EVB1 LP4X ancestry and the same byte-identical DSI
 * panel init sequence as the AISLPC RG43H Pro, so this file is modelled on
 * rk3562-rg43h.dts.  Differences that matter, all measured from the stock
 * firmware's live device tree:
 *
 *   - Panel timing is 1024x768 @ ~60 Hz (RG43H Pro runs ~70 Hz).
 *   - Controls: 17 GPIO buttons and sticks on &saradc1 in4..in7.  There are
 *     no analog L2/R2 and no ADC-button ladder, unlike the RG43H Pro.
 *   - Rumble is one EMA on &gpio0 RK_PB7 (RG43H Pro has two on &gpio3).
 *   - Headphone detect is &gpio0 RK_PA6 and the amplifier enable is the
 *     codec's own spk-ctl on &gpio0 RK_PA7.
 *   - WiFi is an AIC8800DC on USB, not on SDIO, so the sdmmc1 / sdio_pwrseq /
 *     wireless_wlan nodes from the shared dtsi are switched off.  Several of
 *     those pins are gamepad buttons on this board.
 *   - SD card power is an always-on rail; there is no vcc_sd GPIO.
 */

/dts-v1/;

#include <dt-bindings/input/input.h>
#include <dt-bindings/gpio/gpio.h>
#include <dt-bindings/pinctrl/rockchip.h>

#include "rk3562.dtsi"
#include "rk3562-linux.dtsi"
#include "rk3562-rk817.dtsi"
#include "rk3562-darkos.dtsi"

/ {
	model = "NGP45HT";
	compatible = "ngp45ht", "rockchip,rk3562";

	/*
	 * Node name must stay exactly "play_joystick": /usr/local/bin/buttonmon.sh
	 * resolves the event device through
	 * /dev/input/by-path/platform-play_joystick-event-joystick, which is built
	 * from this node's name.  Hyphenating it silently leaves buttonmon pointed
	 * at the wrong event node.
	 */
	play_joystick {
		compatible = "play_joystick";
		joysticks_numbers = <2>;

		/* Measured on this board, holding one stick to a single stop
	 * and reading saradc1: left stick left = ch5 at the rail, left stick
	 * up = ch4 at the rail, right stick left = ch7 at the rail.  So the
	 * X pot of each stick is on the higher channel number, the opposite
	 * of what the vendor DTB claims (it names ch4 "LX", ch6 "RX").
	 * Both X pots also run the other way round: full left is the low
	 * rail, which the driver maps to a positive axis value, hence
	 * invert-x / invert-rx.  Order below is LX, LY, RX, RY to match
	 * stick_chan_names[] = button0..button3. */
		io-channels = <&saradc1 5>, <&saradc1 4>,
			      <&saradc1 7>, <&saradc1 6>;
		io-channel-names = "button0", "button1",
				   "button2", "button3";
		invert-x;
		invert-rx;

		axis-min-value-mv = <250>;
		axis-max-value-mv = <1550>;
		axis-dead-zone-l = <790>;
		axis-dead-zone-h = <1010>;
		axis-division-value = <60>;
		poll-interval = <30>;
		debounce-interval = <100>;

		pinctrl-names = "default";
		pinctrl-0 = <&ngp_gpio_key_pin &ngp_moto_gpio>;
		moto-gpio = <&gpio0 RK_PB7 GPIO_ACTIVE_HIGH>;

		gpio-key-num = <17>;
		key-gpios = <&gpio1 RK_PD3 GPIO_ACTIVE_LOW>,
			    <&gpio1 RK_PD4 GPIO_ACTIVE_LOW>,
			    <&gpio1 RK_PD1 GPIO_ACTIVE_LOW>,
			    <&gpio1 RK_PD2 GPIO_ACTIVE_LOW>,
			    <&gpio0 RK_PC3 GPIO_ACTIVE_LOW>,
			    <&gpio0 RK_PC5 GPIO_ACTIVE_LOW>,
			    <&gpio2 RK_PA0 GPIO_ACTIVE_LOW>,
			    <&gpio2 RK_PA1 GPIO_ACTIVE_LOW>,
			    <&gpio0 RK_PB5 GPIO_ACTIVE_LOW>,
			    <&gpio0 RK_PB6 GPIO_ACTIVE_LOW>,
			    <&gpio0 RK_PB3 GPIO_ACTIVE_LOW>,
			    <&gpio0 RK_PB4 GPIO_ACTIVE_LOW>,
			    <&gpio0 RK_PA5 GPIO_ACTIVE_LOW>,
			    <&gpio3 RK_PA6 GPIO_ACTIVE_LOW>,
			    <&gpio1 RK_PC7 GPIO_ACTIVE_LOW>,
			    <&gpio0 RK_PC6 GPIO_ACTIVE_LOW>,
			    <&gpio0 RK_PC7 GPIO_ACTIVE_LOW>;

		/*
		 * One code per key-gpios entry, in the same order.
		 *
		 * Taken from ROCKNIX's rk3562-ngp45h.dts (AveyondFly/
		 * distribution_rocknix), whose sw1..sw17 list the same 17 GPIOs
		 * in the same order as the vendor micro-gamepad node.  That file
		 * labels its own map "temporary -- verify every GPIO and remap on
		 * the device", so treat this as the best available prior, not as
		 * confirmed.  Only the values below need changing if a button
		 * lands in the wrong slot; rebuilding the DTB takes seconds.
		 */
		key-gpios-map = <BTN_TR BTN_TR2 BTN_TL BTN_TL2
				 BTN_EAST BTN_SOUTH BTN_NORTH BTN_WEST
				 BTN_DPAD_LEFT BTN_DPAD_RIGHT BTN_DPAD_UP
				 BTN_DPAD_DOWN BTN_SELECT BTN_START BTN_MODE
				 BTN_THUMBL BTN_THUMBR>;
	};

	/*
	 * The shared dtsi carries no USB 5V rails, but on this board both USB
	 * ports are switched by RK817-era GPIOs, and the internal AIC8800DC
	 * hangs off the USB2 host bus -- without the host rail enabled nothing
	 * on that bus can enumerate, no matter which driver is loaded.
	 *
	 * Polarity comes from the stock firmware's live tree: the host rail's
	 * line idles high and is asserted low, so ask for an ACTIVE_LOW
	 * descriptor rather than relying on regulator-fixed's
	 * enable-active-high/low property, which only sets the initial level.
	 */
	vcc5v0_usb_host: vcc5v0-usb-host {
		compatible = "regulator-fixed";
		regulator-name = "vcc5v0_usb_host";
		regulator-min-microvolt = <5000000>;
		regulator-max-microvolt = <5000000>;
		regulator-always-on;
		regulator-boot-on;
		gpios = <&gpio3 RK_PC0 GPIO_ACTIVE_LOW>;
		pinctrl-names = "default";
		pinctrl-0 = <&usb_host_pwren>;
	};

	vcc5v0_usb_otg: vcc5v0-usb-otg {
		compatible = "regulator-fixed";
		regulator-name = "vcc5v0_usb_otg";
		regulator-min-microvolt = <5000000>;
		regulator-max-microvolt = <5000000>;
		gpios = <&gpio3 RK_PB0 GPIO_ACTIVE_HIGH>;
		pinctrl-names = "default";
		pinctrl-0 = <&usb_otg_pwren>;
	};

	/*
	 * The shared dtsi's adc_keys ladder does not match this board, which
	 * has four keys on one SARADC input.  Disabled below and re-created
	 * here with the stock thresholds and codes.
	 */
	ngp_adc_keys: adc-keys-ngp {
		compatible = "adc-keys";
		io-channels = <&saradc0 1>;
		io-channel-names = "buttons";
		keyup-threshold-microvolt = <1800000>;
		poll-interval = <100>;

		vol-up-key {
			label = "volume up";
			linux,code = <KEY_VOLUMEUP>;
			press-threshold-microvolt = <17000>;
		};

		vol-down-key {
			label = "volume down";
			linux,code = <KEY_VOLUMEDOWN>;
			press-threshold-microvolt = <300000>;
		};

		menu-key {
			label = "menu";
			linux,code = <KEY_MUTE>;
			press-threshold-microvolt = <600000>;
		};

		back-key {
			label = "back";
			linux,code = <KEY_ESC>;
			press-threshold-microvolt = <980000>;
		};
	};
};

/*
 * vccio_sd (RK817 LDO_REG5, 1.8-3.3 V) is the signalling rail for BOTH card
 * slots.  Leaving it variable while TF2 asks for 3.3 V lets the MMC core raise
 * the rail out from under TF1, which runs the root filesystem -- that hangs
 * boot as soon as TF2 probes.  Pin it to 3.3 V and take UHS off both slots so
 * the rail never switches.  High-speed 50 MHz is ample for ROM loading.
 */
&vccio_sd {
	regulator-min-microvolt = <3300000>;
	regulator-max-microvolt = <3300000>;
};

/*
 * Named vcc1v8_dvp here but 3.3 V always-on in the vendor tree -- the only rail
 * the two device trees disagree about, and the pads that read dead under dArkOS
 * (GPIO1_C1 upward, GPIO2_A) sit downstream of it.  Follow the vendor.
 */
&vcc1v8_dvp {
	regulator-min-microvolt = <3300000>;
	regulator-max-microvolt = <3300000>;
	regulator-always-on;
	regulator-boot-on;
};

&sdmmc0 {
	/delete-property/ sd-uhs-sdr104;
	max-frequency = <50000000>;
};

/* ---- USB ---------------------------------------------------------------- */

/*
 * The shared dtsi leaves the USB2 host controller off because the AISLPC
 * boards have nothing on it.  This board puts both the external USB port and
 * the on-board AIC8800DC on it, so it has to come back on.
 */
&usb_host0_ehci {
	status = "okay";
};

&usb_host0_ohci {
	status = "okay";
};

&u2phy_host {
	vbus-supply = <&vcc5v0_usb_host>;
};

&usb_host0_ehci {
	vbus-supply = <&vcc5v0_usb_host>;
};

&usb_host0_ohci {
	vbus-supply = <&vcc5v0_usb_host>;
};

&usbdrd_dwc3 {
	vbus-supply = <&vcc5v0_usb_otg>;
};

/* ---- Display ------------------------------------------------------------- */

/*
 * LCD power.  The shared dtsi leaves vcc3v3_lcd_n as a regulator-boot-on
 * skeleton on the same GPIO0_B0 line the panel needs.  Claiming that line with
 * the panel's enable-gpios instead (as rk3562-rg43h.dts does) leaves the
 * regulator with no consumer, and the regulator core turns it off during
 * late init -- which kills the panel ~40 s into boot.  Hand the line to the
 * regulator and let the panel hold it via power-supply, the way
 * rk3562-rg52mini.dts does.
 */
&vcc3v3_lcd_n {
	gpios = <&gpio0 RK_PB0 GPIO_ACTIVE_HIGH>;
	enable-active-high;
	pinctrl-names = "default";
	pinctrl-0 = <&ngp_lcd_pwren>;
	status = "okay";
};

&dsi_panel {
	pinctrl-names = "default";
	pinctrl-0 = <&lcd_rst_gpio>;
	power-supply = <&vcc3v3_lcd_n>;

	/* Stock delays: reset/enable 100 ms, init 120 ms, prepare 20 ms. */
	enable-delay-ms = <100>;
	reset-delay-ms = <100>;
	init-delay-ms = <120>;
	prepare-delay-ms = <20>;
	unprepare-delay-ms = <20>;
	disable-delay-ms = <20>;

	panel-init-sequence = [
@@PANEL_INIT_SEQUENCE@@
	];
};

/* 1024x768 at ~60 Hz, taken from the stock timing0 node. */
&dsi_timing0 {
	clock-frequency = <52134144>;
	hactive = <1024>;
	vactive = <768>;
	hfront-porch = <32>;
	hsync-len = <20>;
	hback-porch = <20>;
	vfront-porch = <8>;
	vsync-len = <4>;
	vback-porch = <6>;
	hsync-active = <0>;
	vsync-active = <0>;
	de-active = <0>;
	pixelclk-active = <0>;
};

/* ---- Audio --------------------------------------------------------------- */

/* Amplifier enable is the codec's own pin on this board. */
&rk817_codec {
	use-ext-amplifier;
	spk-ctl-gpios = <&gpio0 RK_PA7 GPIO_ACTIVE_HIGH>;
	hp-volume = <15>;
	spk-volume = <6>;
};

/* Headphone detect moved from RK_PA7 (shared default) to RK_PA6. */
&rk817_sound {
	hp-det-gpio = <&gpio0 RK_PA6 GPIO_ACTIVE_HIGH>;
	pinctrl-0 = <&hp_det>;
	/delete-property/ spk-con-gpios;

	/*
	 * The shared dtsi polls SARADC0 input 4 as a headphone/insertion
	 * detector and hangs a play-pause key off it at a 2 mV threshold.  This
	 * board leaves that input unconnected, so the floating reading reports
	 * phantom KEY_PLAYPAUSE events; drop the whole ladder.
	 */
	/delete-property/ io-channels;
	/delete-property/ io-channel-names;
	/delete-property/ keyup-threshold-microvolt;
	/delete-property/ poll-interval;
	/delete-node/ play-pause-key;
};

/* ---- Power, battery and charge indication ------------------------------- */

&rk817 {
	battery {
		compatible = "rk817,battery";
		ocv_table = @@OCV_TABLE@@;
		design_capacity = <3791>;
		design_qmax = <4000>;
		design_max_voltage = <4120>;
		sleep_enter_current = <150>;
		sleep_exit_current = <180>;
		sleep_filter_current = <100>;
		power_off_thresd = <3450>;
		zero_algorithm_vol = <3950>;
		max_soc_offset = <60>;
		monitor_sec = <5>;
		sample_res = <10>;
		virtual_power = <0>;
		dc_det_gpio = <&gpio3 RK_PA7 GPIO_ACTIVE_HIGH>;
		pinctrl-names = "default";
		pinctrl-0 = <&ngp_charge_led_gpio>;
		charge_green_gpio = <&gpio3 RK_PC1 GPIO_ACTIVE_HIGH>;
		charge_red_gpio = <&gpio3 RK_PC2 GPIO_ACTIVE_HIGH>;
	};

	charger {
		compatible = "rk817,charger";
		min_input_voltage = <4500>;
		max_input_current = <2500>;
		max_chrg_current = <2500>;
		max_chrg_voltage = <4350>;
		chrg_term_mode = <0>;
		chrg_finish_cur = <300>;
		virtual_power = <0>;
		dc_det_adc = <0>;
		dc_det_gpio = <&gpio3 RK_PA7 GPIO_ACTIVE_HIGH>;
		charge_display_gpio = <&gpio3 RK_PC3 GPIO_ACTIVE_HIGH>;
		otg5v_suspend_enable = <1>;
		extcon = <&u2phy>;
		gate_function_disable = <1>;
	};
};

&charge_anim {
	rockchip,uboot-low-power-voltage = <3350>;
	rockchip,screen-on-voltage = <3400>;
};

/* ---- Bring-up of peripherals this board does not have on those pins ----- */

/* Four-key SARADC ladder replaces the shared dtsi's two-key one. */
&adc_keys {
	status = "disabled";
};

/*
 * WiFi is USB-attached, so the SDIO WiFi stack from the shared dtsi must not
 * claim PB3 (a gamepad button here), PB4 (button), PA6 (headphone detect) or
 * sdmmc1.
 */
/*
 * Second TF slot.  sdmmc1 (ff890000) is wired to a removable card on this
 * board, not to an SDIO WiFi combo module -- the wireless chip is the USB
 * AIC8800DC -- so it becomes /dev/mmcblk2, which is exactly the node
 * /usr/local/bin/Switch to SD2 for Roms.sh expects on non-RK3326 hardware.
 *
 * Pin set taken from the vendor tree: bus4 = GPIO1_C1..C4, cmd = C5,
 * clk = C6, det = PD0, matching the kernel's plain sdmmc1_* groups.
 *
 * UHS is deliberately not requested.  Both slots share one I/O rail
 * (vccio_sd / RK817 LDO_REG5), so it cannot be switched to 1.8 V for one card
 * while the other stays at 3.3 V; the vendor DT's sd-uhs-sdr104 looks
 * inherited from the EVB reference.  High-speed 50 MHz is plenty for ROMs.
 *
 * Card detect: this slot's CDETECT pad reads "absent" even with a 128 GiB
 * card inserted, so broken-cd is kept to make the core poll at all.
 *
 * SD2 does not come up on this port and the reason is not in this node.
 * Measured: with the node reduced to exactly the vendor's working one --
 * same vqmmc (LDO_REG5), same bus4/cmd/clk/det groups (confirmed in
 * pinmux-pins), same clocks/resets, sd-uhs-sdr104 and the 200 MHz ceiling
 * -- the host still runs the 400/300/200/100 kHz probe ladder and gets no
 * OCR response, while stock EmuELEC on kernel 6.1 reads the same card as
 * "mmc2: new high speed SDXC".  UHS stays off here because vccio_sd is
 * shared with TF1, which hosts the root filesystem.
 */
&sdmmc1 {
	/delete-property/ no-sd;
	/delete-property/ mmc-pwrseq;
	/delete-property/ cap-sdio-irq;
	/delete-property/ keep-power-in-suspend;
	/delete-property/ supports-sdio;
	/delete-property/ supports-rk912;
	/delete-property/ sd-uhs-sdr104;

	no-sdio;
	no-mmc;
	bus-width = <4>;
	cap-sd-highspeed;
	cap-mmc-highspeed;
	disable-wp;
	broken-cd;
	max-frequency = <50000000>;
	vqmmc-supply = <&vccio_sd>;
	pinctrl-names = "default";
	pinctrl-0 = <&sdmmc1_bus4 &sdmmc1_cmd &sdmmc1_clk &sdmmc1_det>;
	status = "okay";
};

&sdio_pwrseq {
	status = "disabled";
};

&wireless_wlan {
	status = "disabled";
};

/* The stick-LED MCU UART would take PD2, which is a gamepad button. */
&uart1 {
	status = "disabled";
};

/*
 * The stock board puts the RK628 RGB-to-HDMI bridge on i2c3 with its own
 * reset/enable pins, not on i2c4 as the shared dtsi assumes.  Left disabled
 * for bring-up so it does not claim GPIO3_C0/C1/C2 or GPIO0_A0.
 */
&i2c4_rk628 {
	status = "disabled";
};

&rk628_sound {
	status = "disabled";
};

&rgb {
	status = "disabled";
};

&route_rgb {
	status = "disabled";
};

/*
 * SD-card power is a fixed rail on this board.  The shared dtsi drives it
 * from GPIO0_A5, which is a gamepad button here, so make the regulator
 * always-on and drop its GPIO.  Likewise the LED rail's GPIO0_C7 is a button.
 */
&vcc_sd {
	compatible = "regulator-fixed";
	regulator-always-on;
	regulator-boot-on;
	/delete-property/ gpios;
	/delete-property/ enable-active-low;
	/delete-property/ states;
	/delete-property/ pinctrl-0;
	/delete-property/ pinctrl-names;
};

/*
 * The stick-LED rail is gated by GPIO0_C7 on the AISLPC boards, which is a
 * gamepad button here, so the rail goes away entirely rather than being
 * re-parented.
 */
&led_vcc {
	status = "disabled";
	/delete-property/ gpios;
	/delete-property/ enable-active-high;
	/delete-property/ pinctrl-0;
	/delete-property/ pinctrl-names;
};

/* ---- Pin control -------------------------------------------------------- */

&pinctrl {
	buttons {
		ngp_gpio_key_pin: ngp-gpio-key-pin {
			rockchip,pins =
				<1 RK_PD3 RK_FUNC_GPIO &pcfg_pull_up>,
				<1 RK_PD4 RK_FUNC_GPIO &pcfg_pull_up>,
				<1 RK_PD1 RK_FUNC_GPIO &pcfg_pull_up>,
				<1 RK_PD2 RK_FUNC_GPIO &pcfg_pull_up>,
				<0 RK_PC3 RK_FUNC_GPIO &pcfg_pull_up>,
				<0 RK_PC5 RK_FUNC_GPIO &pcfg_pull_up>,
				<2 RK_PA0 RK_FUNC_GPIO &pcfg_pull_up>,
				<2 RK_PA1 RK_FUNC_GPIO &pcfg_pull_up>,
				<0 RK_PB5 RK_FUNC_GPIO &pcfg_pull_up>,
				<0 RK_PB6 RK_FUNC_GPIO &pcfg_pull_up>,
				<0 RK_PB3 RK_FUNC_GPIO &pcfg_pull_up>,
				<0 RK_PB4 RK_FUNC_GPIO &pcfg_pull_up>,
				<0 RK_PA5 RK_FUNC_GPIO &pcfg_pull_up>,
				<3 RK_PA6 RK_FUNC_GPIO &pcfg_pull_up>,
				<1 RK_PC7 RK_FUNC_GPIO &pcfg_pull_up>,
				<0 RK_PC6 RK_FUNC_GPIO &pcfg_pull_up>,
				<0 RK_PC7 RK_FUNC_GPIO &pcfg_pull_up>;
		};

		ngp_moto_gpio: ngp-moto-gpio {
			rockchip,pins = <0 RK_PB7 RK_FUNC_GPIO &pcfg_pull_none>;
		};
	};

	headphone {
		/* Stock board detects headphones on RK_PA6, not RK_PA7. */
		hp_det: hp-det {
			rockchip,pins = <0 RK_PA6 RK_FUNC_GPIO &pcfg_pull_up>;
		};
	};

	charge-led {
		ngp_charge_led_gpio: ngp-charge-led-gpio {
			rockchip,pins =
				<3 RK_PC1 RK_FUNC_GPIO &pcfg_pull_up>,
				<3 RK_PC2 RK_FUNC_GPIO &pcfg_pull_up>;
		};
	};

	lcd {
		ngp_lcd_pwren: ngp-lcd-pwren {
			rockchip,pins = <0 RK_PB0 RK_FUNC_GPIO &pcfg_pull_up>;
		};
	};

	usb {
		usb_host_pwren: usb-host-pwren {
			rockchip,pins = <3 RK_PC0 RK_FUNC_GPIO &pcfg_pull_none>;
		};

		usb_otg_pwren: usb-otg-pwren {
			rockchip,pins = <3 RK_PB0 RK_FUNC_GPIO &pcfg_pull_none>;
		};
	};
};
