# Passport Chinese font

`passport_font_16.c` is generated from Adobe Source Han Sans CN Regular,
licensed under SIL Open Font License 1.1; see `SOURCE_HAN_LICENSE.txt`.
Source: https://github.com/adobe-fonts/source-han-sans/tree/release/SubsetOTF/CN

The checked-in symbol inventory covers printable ASCII, GB2312 (including
all 6,763 Chinese characters), standard Big5 CJK (13,061 traditional Chinese
characters, with overlap), and extra punctuation: 16,220 glyphs total. The
traditional repertoire is validated against the original font cmap before
generation. This preserves Muse text instead of applying lossy simplified
conversion. It does not cover arbitrary Unicode, all rare names, HKSCS or emoji.
LVGL shows placeholders for unsupported characters.

Generation uses `lv_font_conv@1.5.3`, size 16, 2 bpp, no compression or kerning.
The font's actual line height is 21 px. UI pagination uses this metric, not
the nominal point size. Bitmap data lives in read-only flash.

```sh
npx --yes --package lv_font_conv@1.5.3 lv_font_conv \
  --font /path/to/SourceHanSansCN-Regular.otf \
  --symbols "$(cat passport_font_symbols.txt)" \
  --size 16 --bpp 2 --format lvgl --no-compress --no-kerning \
  --lv-include lvgl.h --lv-font-name passport_font_16 \
  --output passport_font_16.c
```

Run `python3 -m unittest discover -s tests -p test_passport.py` from `esp32/`
to check the generated glyph inventory. Device rendering is a separate check.
