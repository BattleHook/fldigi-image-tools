# Updates

## Planned for the next update

These improvements are planned, not included in v1.01. No version or release date has been assigned.

- Use the original capture's filename as the default for JSON exports, with a `.json` extension.
- Use the mouse wheel over the **Shift -** and **Shift +** buttons for faster shift adjustments.
- Scroll over the crosshair or zoom area to move between rows faster: up for earlier rows, down for later rows.
- Select the previous image in the browser after deleting the current image.
- Add **Check All** and **Uncheck All** to the missing-image results. Neither button applies removals.
- Increase the Step Zoom zoom-out range when using **Ctrl + mouse wheel**.
- Add an **Open Backup Folder** button after cleanup.

## v1.01

- Fixed a scan failure (`Unexpected ADIF data at byte 0`) when an FLdigi logbook starts with a `File:` line before the ADIF header. Cleanup preserves that line byte-for-byte; no manual logbook edit is needed.

## v1.0

- First public release: WEFAX image correction and safe cleanup of FLdigi logbook entries that reference missing images.
