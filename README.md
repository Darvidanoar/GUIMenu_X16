# GUIMenu_X16

A mouse-driven program launcher for the [Commander X16](https://www.commanderx16.com/), written in 6502 assembly.

Browse the folders on your SD card, see the files in each one, and double-click a `.PRG` to load and run it. It's styled after an Amiga Workbench 2.0/3.1 window.

Preview images can be added to the folder as PNG files making them easy to create.  The typical way to create preview images would be to launch the game in the emulator and hit ctrl-p to take a screenshot.

![GUIMenu running in the X16 emulator](docs/screenshot.png)

## Features

- **Folder tree:** shows the folders on the SD card, each with an orange folder icon. Click a folder to open it. Click its `[+]`/`[-]` box to expand or collapse it.
- **File list:** shows the files in the open folder. Programs (`.PRG`) are listed first and shown in blue. Then come pictures (`.PNG`) and text files (`.TXT` and `.MD`) in black, since they can be previewed, then everything else in dark grey, since there is nothing to do with those. Each group is sorted alphabetically, ignoring upper/lower case.
- **Double-click to run:** double-click a `.PRG` (or highlight it and press RETURN) to load and run it. The program starts in its own folder, so it can find its data files.
- **Keyboard navigation:** Up/Down move through a list, Left/Right go up and down the folder levels, and Tab switches lists. See [Controls](#controls).
- **Scroll bars:** Amiga style, with both arrows at the bottom. Click the arrows to scroll a line (hold to repeat), click the track to scroll a page, or drag the thumb. The mouse wheel scrolls the list under the pointer.
- **Amiga Workbench look:** a grey window with raised 3D edges and a blue title bar, sunken list boxes and a status line, on a dark blue desktop. The close, zoom and depth gadgets are decoration only.
- **Status line:** shows the path of the open folder, e.g. `/GAMES/ARCADE`.
- **Desktop logo:** the Commander X16 logo picture at the top left, drawn with five 64x64 hardware sprites.
- **Preview panel:** shows a `.PNG` picture from the open folder, shrunk (or enlarged) to fit. If the highlighted file is a `.PNG`, that one is shown; otherwise the first `.PNG` in the folder is. So putting `GAME.PNG` next to `GAME.PRG` gives the folder a picture. See [Preview pictures](#preview-pictures).
- **Text preview:** highlight a `.TXT` or `.MD` file and its text is shown in the preview panel, with a scroll bar for longer files. See [Text preview](#text-preview).

## Requirements

- A Commander X16 or the [x16emu](https://github.com/X16Community/x16-emulator) emulator. Developed and tested on ROM R49.
- [cc65](https://cc65.github.io/) to build it (`cl65` must be on your `PATH`).

## Building

```sh
make
```

This runs:

```sh
cl65 -t cx16 -C cx16-asm.cfg -u __EXEHDR__ -o GUIMENU.PRG -l GUIMENU.LIST -Ln GUIMENU.SYM GUIMENU.ASM
```

`-u __EXEHDR__` adds a `10 SYS 2061` BASIC line to the start of the program so it can be started with `RUN`. `make clean` removes the build output.

A pre-built `GUIMENU.PRG` is included in the repository.

## Running

Copy `GUIMENU.PRG` to your SD card, then type:

```
LOAD "GUIMENU.PRG"
RUN
```

In the emulator you can use an SD card image:

```sh
x16emu -sdcard sdcard.img -prg GUIMENU.PRG -run
```

If you leave out `-sdcard`, the emulator uses the host file system as device 8.

To start the launcher automatically, save it on the SD card as `AUTOBOOT.X16`.

## Controls

### Mouse

| Action | What it does |
| --- | --- |
| Click a folder name | Open the folder (expands it the first time) |
| Click a folder's `[+]` / `[-]` box | Expand or collapse the folder |
| Click a file | Highlight it |
| Double-click a `.PRG` | Load and run it |
| Click a scroll bar arrow | Scroll one line (hold to repeat) |
| Click the scroll bar track | Scroll a page up or down |
| Drag the scroll bar thumb | Scroll to that position |
| Mouse wheel | Scroll the list (or text preview) under the pointer |
| Click the text preview | Give it the keyboard focus, to scroll it with the keys |

### Keyboard

The keyboard works in one place at a time: the folder list, the file list, or the text preview (when a text file is shown). The list with the keyboard has a blue highlight bar; the other's is dark grey, and both are grey when the keyboard is in the text. `Tab` moves on (folders, files, text, then folders again) and `Shift+Tab` goes back. Clicking a list or the text also moves the keyboard to it.

| Key | Folder list | File list | Text preview |
| --- | --- | --- | --- |
| `Up` / `Down` | Open the folder above / below (without expanding it) | Move the highlight one file | Scroll a line |
| `Page Up` / `Page Down` | Move a page | Move a page | Scroll a page |
| `Home` / `End` | Open the first / last folder | First / last file | Top / end of the text |
| `Right` | Expand the open folder and open its first sub-folder | Same | Same |
| `Left` | Open the parent of the open folder | Same | Same |
| `RETURN` | Go to the file list | Run the highlighted program | Go back to the file list |
| `Q`, `ESC` or `RUN/STOP` | Quit to BASIC | Quit to BASIC | Quit to BASIC |

## Preview pictures

GUIMenu decodes the PNG itself on the X16, so any normal PNG works. That includes greyscale, colour, palette and transparent images, at any bit depth (1, 2, 4, 8 or 16 bits). Interlaced PNGs aren't supported. Rows can be up to 8192 bytes, so RGB images up to 2730 pixels wide.

- **Fitting:** the panel at the bottom right of the window covers 320x240 screen pixels, half the screen each way. The picture is scaled to fit it, keeping its shape, and centred across the panel. 640x480 and 320x240 screenshots fill it exactly (a 320x240 one pixel for pixel).
- **Colours:** VERA shows 4096 colours, 256 at once. The preview gets 111 of the 256 palette entries. Each colour in the picture is reduced to 4 bits per channel and given its own entry. Screenshots of X16 programs come out exact. Pictures with more than 111 colours, such as photos, use the closest colour once the entries run out.
- **Speed:** decoding happens on the 8 MHz 6502, so a big picture takes a while. A 640x480 screenshot (the size the emulator saves) takes about 12 seconds; 320x240 takes about 5 seconds. Smaller PNGs show up faster, so shrink large screenshots before copying them to the SD card. Decoding starts a third of a second after you stop moving through the lists, and stops when you press a key or click, so it never gets in the way.
- **Transparency:** pixels that are more than half transparent show the panel's grey background.

## Text preview

When the highlighted file ends in `.TXT` or `.MD`, the preview panel shows its text, black on white, instead of a picture. It appears a third of a second after the file is highlighted.

- **Size:** the panel shows 30 lines of 39 characters, with a scroll bar in its last column.
- **Scrolling:** the scroll bar works like the lists' (arrows, track and thumb), as does the mouse wheel over the text. To use the keyboard, press `Tab` until neither list is highlighted (or click the text), then use `Up`/`Down`, `Page Up`/`Page Down` and `Home`/`End`.
- **Long files:** the whole file is read and laid out when it is chosen, so scrolling is instant. That takes about 0.7 seconds for a 20 KB file. Up to 2048 lines are kept (about 2.5 seconds to read); anything after that is left out.
- **Wrapping:** long lines wrap at the last space that fits. A word wider than the panel is cut at the edge.
- **Line endings:** Windows (CR+LF), Unix (LF) and old Mac (CR) files all work. Tabs move to the next multiple of 4 columns.
- **Characters:** plain ASCII is shown as it is, including `` \ ^ _ ` { | } ~ ``, which the X16's PETSCII character set lacks; GUIMenu adds its own shapes for them (file names with `_` now show properly too). Each UTF-8 character outside ASCII (such as `é`) is shown as one `?`.
- **Markdown:** shown as plain text, with its `#`, `*` and other marks.

## How programs are launched

Most X16 programs load at `$0801`, which is where GUIMenu is running. So GUIMenu can't load them itself without overwriting its own code. It handles this in one of two ways:

- **Load address `$0801`** (BASIC programs, and machine-code programs with a `SYS` line): GUIMenu resets the screen and prints the BASIC DOS-wedge command `↑NAME` (load and run) on the screen. It then queues a RETURN keypress and warm-starts BASIC. BASIC runs the command as if it had been typed, so BASIC's own memory pointers are set up correctly.
- **Any other load address:** a small loader is copied to `$0400`. It loads the file to the address in its header and jumps there. If the program ends with `RTS`, it returns to BASIC's `READY.` prompt.

## Limitations

- Up to 255 files per folder and 250 folders in the tree. If a folder has more files than that, programs are always listed and some of the other files are left out.
- File and folder names are stored up to 61 characters.
- Names are sent to DOS in upper case. This works because CMDR-DOS ignores case when it looks for a file.
- Preview pictures: no interlaced PNGs, and up to 8192 bytes per row. The checksums in the file are not checked.

## Project layout

| File | Contents |
| --- | --- |
| `GUIMENU.ASM` | Constants, variables, start-up, main loop, mouse handling, scroll bars |
| `SCREEN.ASM` | All screen drawing, the palette, the logo sprites and the custom characters |
| `TREE.ASM` | The folder tree and record storage in banked RAM |
| `DOS.ASM` | DOS commands and reading directory listings |
| `LAUNCH.ASM` | Loading and running the chosen program |
| `PNG.ASM` | The preview panel: finding, decoding (inflate, row filters) and showing PNG pictures |
| `TEXT.ASM` | The preview panel for `.TXT` and `.MD` files: reading, word-wrapping and showing the text |
| `INC/x16.inc` | X16 addresses, KERNAL routines and macros |
| `CommanderX16_320.png` | The logo picture (320x55) |
| `LOGO.PAL`, `LOGO.RLE` | The logo's colours and pixels, made from the PNG and included in the program |
| `tools/logo2bin.py` | Makes `LOGO.PAL` and `LOGO.RLE` from the PNG (needs Python and Pillow; only needed to change the logo) |
| `Makefile` | Build script |

The source is commented throughout, including an overview at the top of each file.


## License

Released under the [MIT License](LICENSE).
