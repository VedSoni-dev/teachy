---
name: Google Sheets
bundleIds: []
sites: [docs.google.com/spreadsheets, sheets.google.com]
summary: Google's spreadsheet in the browser. Shortcuts are the Mac ones.
---
## Layout
- Top left: the file title. Under it the menu bar: File, Edit, View, Insert, Format, Data, Tools, Extensions, Help.
- Under that the toolbar: undo, redo, print, paint format, zoom, currency, percent, decimal places, number format (123), font, size, bold, text colour, fill colour, borders, merge, alignment, wrapping, link, comment, chart, filter, functions.
- Under the toolbar: the Name box at the left (shows the selected cell, such as B4) and the formula bar (fx).
- The grid, with column letters and row numbers.
- Bottom left: + adds a sheet, the list icon shows all sheets, then the sheet tabs. Bottom right: the sum or count of the selected cells.
- Top right: version history, comments, Share.

## Where things are
- Keep a header row in view: View > Freeze.
- Filter buttons on the header row: Data > Create a filter.
- Sort: Data > Sort range.
- A private filter that does not disturb others: a filter view, under Data (Filter views, or Create filter view).
- Pivot table: Insert > Pivot table. Chart: Insert > Chart.
- Colour cells by rule: Format > Conditional formatting.
- Dropdown in a cell: Insert > Dropdown, or Data > Data validation.
- Number, date and currency formats: Format > Number.
- Wrap long text: Format > Wrapping > Wrap.
- Remove duplicates or trim spaces: Data > Data cleanup.
- Split one column into several: Data > Split text to columns.
- Lock cells or a sheet: Data > Protect sheets and ranges.
- Import a CSV or Excel file: File > Import. Save as Excel or CSV: File > Download.
- Scripts: Extensions > Apps Script.
- Rename, duplicate, hide or delete a sheet: Control-click its tab.

## Gotchas
- A normal filter changes what everyone sees. Use a filter view when others are in the file.
- Whether formulas use commas or semicolons, and how dates are read, depends on File > Settings > Locale.
- A date that sits left-aligned in its cell was read as text, not as a date.
- Download as CSV saves only the sheet that is open.
- #REF! means a formula points at cells that were deleted. A column of ### is just too narrow.

## Shortcuts
- Fill down: Cmd+D. Fill right: Cmd+R. Paste values only: Shift+Cmd+V.
- Absolute reference ($A$1) while editing a formula: F4 (Fn+F4 on a Mac laptop).
- Select a column: Ctrl+Space. Select a row: Shift+Space.
- Jump to the edge of the data: Cmd+Arrow.
- Insert a link: Cmd+K. Find and replace: Shift+Cmd+H.
- Show formulas: Ctrl+Backtick. All shortcuts: Cmd+Slash.
