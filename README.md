# FLdigi Image Tools

**WEFAX post-processing and logbook cleanup for FLdigi on Windows.** Find ADIF entries that point to missing weather fax images, or correct and export an existing chart. This is a standalone community tool, not part of FLdigi.

## Get started with the portable Windows release

The portable package requires 64-bit Windows. It works with either 32-bit or 64-bit FLdigi.

1. Download the portable ZIP from [Releases](https://github.com/BattleHook/fldigi-image-tools/releases) and extract it to a writable folder. Keep `FldigiImageTools.exe` and [`Cleaner.ini`](./Cleaner.ini) together. No installer or separate AutoHotkey installation is required.
2. Check the logbook path and WEFAX image folder in [`Cleaner.ini`](./Cleaner.ini). `{profile}` means your Windows user folder.
3. Open `FldigiImageTools.exe`. Choose **Scan** to review missing-image entries, or **WEFAX Images** to open a linked chart.

See the [short manual](./MANUAL.md) for both workflows, including how to restore a logbook backup or reload saved image adjustments.

## Scope and safeguards

The supplied rule reads `MODE=FAX` records with an `RX:` PNG reference in `NOTES`. A scan does not modify the logbook. Before applying removals or saving an image with an `ENH:` link, close FLdigi; the app checks that the logbook has not changed and backs it up before replacing it. Uncertain references and unavailable folders are not treated as missing files. Work on a copy first if you are unsure.

## Practice images

Two [synthetic practice images](./MANUAL.md#practice-with-synthetic-images) demonstrate tilt, alignment, cropping, and sideways line jumps without using any received weather charts or reading your station logbook.

## Running from source

Install [AutoHotkey v2](https://www.autohotkey.com/) only if you want to run the `.ahk` source or tests. Keep the `.ahk` files, [`FldigiImageTools.ico`](./FldigiImageTools.ico), and [`Cleaner.ini`](./Cleaner.ini) together in a writable folder and open [`FldigiLogbookCleaner.ahk`](./FldigiLogbookCleaner.ahk).

Run `AutoHotkey64.exe FldigiLogbookCleaner.ahk --preview` for the built-in synthetic chart, or `AutoHotkey64.exe Cleaner.Tests.ahk` for disposable-file tests. Use the full path to `AutoHotkey64.exe` if it is not on your PATH. To use the supplied practice PNGs from source, replace `.\FldigiImageTools.exe` in the [manual's preview command](./MANUAL.md#practice-with-synthetic-images) with `AutoHotkey64.exe FldigiLogbookCleaner.ahk`.

To build the portable app, run [Ahk2Exe](https://github.com/AutoHotkey/Ahk2Exe) from the source folder with `FldigiLogbookCleaner.ahk` as input, `FldigiImageTools.exe` as output, and the [AutoHotkey v2.0.30](https://github.com/AutoHotkey/AutoHotkey/releases/tag/v2.0.30) x64 `AutoHotkey64.exe` as the base. Keep `Cleaner.ini` and the `examples` folder beside the result.

## Support and license

Use the repository's Issues tab for reports; share synthetic examples rather than private logbooks or station paths. If you find the tool useful, you can [support development on Ko-fi](https://ko-fi.com/battlehook). Support is entirely optional.

[MIT License](./LICENSE).

The portable executable embeds the AutoHotkey v2.0.30 runtime, which has its own GPL license. The portable ZIP includes the runtime license, and the release provides the matching runtime source separately.
