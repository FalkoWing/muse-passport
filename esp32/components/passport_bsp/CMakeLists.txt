set(passport_srcs)
if(CONFIG_MUSE_BOARD_FOLOTOY_PASSPORT)
    list(APPEND passport_srcs "src/bsp_i2c.c"
         "src/bsp_display.c"
         "src/bsp_display_lvgl.c"
         "src/bsp_display_rounding.c"
         "src/bsp_button.c"
         "src/bsp_audio.c"
         "src/bsp_es8311_sleep_check.c"
         "src/bsp_battery.c")
endif()
# Requirements are discovered before Kconfig. Managed dependencies are added
# by idf_component.yml only for Passport; all built-in requirements stay here.
idf_component_register(
    SRCS ${passport_srcs}
    INCLUDE_DIRS "include"
    REQUIRES esp_driver_gpio esp_driver_spi esp_driver_ledc esp_driver_i2c esp_driver_i2s esp_lcd esp_adc
    PRIV_REQUIRES esp_timer
)
