;******************************************************************
; X16 GUI Menu
;
; A mouse driven program launcher for the Commander X16, styled
; after an Amiga Workbench 2.0/3.1 window on a dark blue desktop.
;
;   [ COMMANDER X16 logo ]                     <- desktop logo, an
;                                                   image shown with
;                                                   sprites
;  +----------------------------------------------------------+
;  |[o]| SD Card Program Launcher                   |[=]|[#]| <- blue
;  |----------------------------------------------------------|  title
;  |  Folders:              Files:                            |  bar
;  |  +---------------+-+   +-----------------------------+-+ |
;  |  |[-] SD Card    |#|   | HELLO.PRG                   |#| |
;  |  | [+] GAMES     | |   | readme.txt                  |^| |
;  |  | [+] TOOLS     | |   +-----------------------------+v+ |
;  |  |               | |     Preview:                        |
;  |  |               | |   +-------------------------------+ |
;  |  |               | |   |                               | |
;  |  |               | |   |   320x240 pixels: half the    | |
;  |  |               |^|   |   screen each way             | |
;  |  |               |v|   |                               | |
;  |  +---------------+-+   +-------------------------------+ |
;  |  /GAMES                    Double-click a program ...     |
;  +----------------------------------------------------------+
;
; Like Workbench, everything is grey with 3D edges: a light (white)
; edge at the top and left and a dark (black) one at the bottom and
; right makes a thing look raised (the window); the other way round
; makes it look sunken (the list boxes).
;
;   - Left list:   a tree of the folders on the SD card (tall and
;                  the full height of the window).
;                  Click a folder name to open it.
;                  Click its [+]/[-] box to expand or collapse it.
;   - Top right:   the files in the open folder: programs (.PRG,
;                  in blue) first, then pictures (.PNG), then
;                  text (.TXT, .MD), then the rest, each group in
;                  name order. Double-click a program to run it.
;   - Bottom right: a 320x240 pixel preview of the folder's
;                  picture: the highlighted .PNG file, or else the
;                  first .PNG in the folder, shrunk to fit (see
;                  PNG.ASM). A highlighted .TXT or .MD file shows
;                  its text there instead (see TEXT.ASM).
;   - Scroll bars: as on the Amiga, both arrows are at the bottom.
;                  Click the arrows to scroll a line (hold to
;                  repeat), click the track above/below the thumb
;                  to scroll a page, or drag the thumb. The mouse
;                  wheel scrolls the list under the pointer.
;   - The window's close, zoom and depth gadgets are only
;     decoration.
;   - Keyboard: Tab moves between the folder list, the file list
;     and (when a text file is shown) the text preview; Shift+Tab
;     goes back. The one that has the "focus" has the blue
;     highlight bar (with the text, neither list has it). Up,
;     Down, Page Up, Page Down, Home and End move through it;
;     moving in the folder list opens that folder (without
;     expanding it), and in the text they scroll it. Right expands
;     the open folder and opens its first sub-folder, and Left
;     opens its parent, wherever the focus is. RETURN on a program
;     runs it.
;   - Q, ESC or RUN/STOP quits back to BASIC.
;
; Source files (all assembled together as one unit, see the
; .include lines at the bottom of this file):
;   GUIMENU.ASM  constants, variables, start-up, main loop, mouse,
;                scroll bars
;   SCREEN.ASM   everything that draws on the screen, custom glyphs,
;                palette
;   TREE.ASM     the folder tree and record storage in banked RAM
;   DOS.ASM      sending DOS commands and reading directory listings
;   LAUNCH.ASM   loading and running the chosen program
;   PNG.ASM      the preview panel: decoding and showing PNG files
;   TEXT.ASM     the preview panel: showing .TXT and .MD files
;
; Build:  make
;         (runs: cl65 -t cx16 -C cx16-asm.cfg -u __EXEHDR__ ...)
;         "-u __EXEHDR__" adds the BASIC line "10 SYS 2061" to the
;         front of the program so it can be started with RUN.
; Run:    LOAD "GUIMENU.PRG"  then  RUN
;******************************************************************

.include "INC/x16.inc"

; KERNAL routine that isn't in x16.inc: put the character in A into
; the keyboard buffer, as if it had been typed.
KBDBUF_PUT        := $FEC3

;------------------------------------------------------------------
; Banked RAM usage
;
; The X16 has 8 KB "windows" of banked RAM at $A000-$BFFF. Writing a
; bank number to RAM_BANK ($00) chooses which 8 KB bank appears
; there. Bank 0 is used by the KERNAL and DOS, so we use banks 1-10.
;
; Every folder name and file name is stored as a 64 byte "record",
; so one 8 KB bank holds 128 records:
;
;   byte 0     REC_DEPTH  tree nodes: how deep the folder is (root=0)
;   byte 1     REC_FLAGS  tree nodes: FLAG_EXPANDED / FLAG_NOKIDS
;                         files:      FLAG_PRG / FLAG_PNG /
;                                     FLAG_TXT
;   bytes 2-63 REC_NAME   the name, ending with a 0 byte
;------------------------------------------------------------------
TREE_BANK         = 1             ; banks 1-2 : folder tree nodes
FILE_BANK         = 3             ; banks 3-4 : files in current folder
TDIR_BANK         = 5             ; bank 5    : sub-folders just read
                                  ; banks 6-10: the PNG decoder (see
                                  ;   WIN_BANK and MAP_BANK in PNG.ASM)

REC_DEPTH         = 0             ; offsets inside a record
REC_FLAGS         = 1
REC_NAME          = 2
NAME_MAX          = 61            ; longest name we keep (+1 for the 0)

MAX_TREE          = 250           ; most folders the tree can show
MAX_FILES         = 255           ; most files listed for one folder
                                  ;   (255 fits in a byte, and $FF
                                  ;   still means "no file"). If a
                                  ;   folder has more, programs are
                                  ;   kept and other files dropped.
MAX_TDIRS         = 128           ; most sub-folders read for one folder
MAX_DEPTH         = 30            ; deepest folder level we will open

FLAG_EXPANDED     = $01           ; tree node's sub-folders are shown
FLAG_NOKIDS       = $02           ; tree node has no sub-folders
FLAG_PRG          = $01           ; file name ends in .PRG
FLAG_PNG          = $02           ; file name ends in .PNG
FLAG_TXT          = $04           ; file name ends in .TXT or .MD

;------------------------------------------------------------------
; Screen layout (80 columns x 60 rows text mode)
; Columns are numbered 0-79 from the left, rows 0-59 from the top.
;------------------------------------------------------------------
SCREEN_COLS       = 80
SCREEN_ROWS       = 60

; The desktop logo is a 320x55 pixel picture (made from
; CommanderX16_320.png by tools/logo2bin.py) shown with 5 sprites of
; 64x64 pixels side by side. Sprites are positioned in pixels; in
; this 80 column mode one sprite pixel is one screen pixel, so the
; logo is 40 columns wide and fits in the 9 rows above the window.
LOGO_X            = 16            ; top left corner, in pixels
LOGO_Y            = 8
LOGO_SPRITES      = 5             ; sprites 1-5 (sprite 0 is the mouse)
LOGO_SPR_BYTES    = 64*64         ; 64x64 pixels, 1 byte per pixel
LOGO_VRAM         = $15000        ; where the sprite pixels go in VRAM
                                  ;   ($15000-$19FFF; the preview's
                                  ;   tiles fill $00000-$12CFF and its
                                  ;   map $14000-$14FFF, see PNG.ASM)
LOGO_PAL_FIRST    = 128           ; logo colours: palette entries 128-255

; the window. Its raised outer edge is drawn on the desktop cells
; just outside it (row WIN_T-1, row WIN_B+1, and the columns either
; side), so the window must not touch the screen edges.
WIN_L             = 1             ; left border column
WIN_R             = 78            ; right border column
WIN_T             = 9             ; top row = the title bar
WIN_B             = 58            ; bottom border row
; The boxes inside the window:
;
;   +--------------------------------+ +----------------+
;   | Folders (tall, on the left)    | | Files          |
;   |                                | |                |
;   |                                | +----------------+
;   |                                |   Preview:
;   |                                | +----------------+
;   |                                | | 320x240 pixels |
;   |                                | |                |
;   +--------------------------------+ +----------------+
;
; Both lists start on row LIST_TOP, but they are different heights,
; so each has its own number of rows (TREE_ROWS, FILE_ROWS). A box's
; edge is drawn in the row above and the row below its contents.
LABEL_ROW         = 11            ; "Folders:" "Files:"
BOX_T             = 12            ; top edge of the two list boxes
LIST_TOP          = 13            ; first row of both lists
TREE_ROWS         = 42            ; folders: rows 13..54
TREE_BOX_B        = LIST_TOP+TREE_ROWS ; row 55: bottom edge
FILE_ROWS         = 9             ; files: rows 13..21
FILE_BOX_B        = LIST_TOP+FILE_ROWS ; row 22: bottom edge

; The preview: 40 x 30 character cells = 320 x 240 screen pixels,
; half the screen each way, at the bottom right, its bottom edge
; level with the folder box's. A 640x480 screenshot shows at half
; size, a 320x240 one pixel for pixel.
PREV_ROWS         = 30            ; picture: rows 25..54
PREV_TOP          = TREE_BOX_B-PREV_ROWS ; row 25
PREV_BOX_T        = PREV_TOP-1    ; row 24: top edge
PREV_LABEL_ROW    = PREV_BOX_T-1  ; row 23: "Preview:"
STATUS_ROW        = 57            ; status line (path and hint)
STATUS_X          = 3             ; where the path starts

.assert WIN_L >= 1 && WIN_R <= 78 && WIN_T >= 1 && WIN_B <= 58, error, "window must leave room for its outer edge"
.assert PREV_LABEL_ROW > FILE_BOX_B, error, "the preview must fit below the file list"
.assert TREE_BOX_B < STATUS_ROW, error, "the boxes must end above the status line"

; the boxes: _L/_R = left/right edge column, _X/_W = the columns
; for text, _SB = the scroll bar column. The file list sits right
; above the preview and is the same width.
TREE_L            = 3
TREE_X            = 4             ; folder names: columns 4..31
TREE_W            = 28
TREE_SB           = 32
TREE_R            = 33
PREV_L            = 35
PREV_X            = 36            ; preview: columns 36..75
PREV_W            = 40
PREV_R            = 76
FILE_L            = PREV_L
FILE_X            = PREV_X        ; file names: columns 36..74
FILE_W            = PREV_W-1      ;   (the last column is the
FILE_SB           = PREV_X+FILE_W ;   scroll bar, column 75)
FILE_R            = PREV_R

.assert TREE_X+TREE_W = TREE_SB && TREE_SB+1 = TREE_R, error, "tree columns out of order"
.assert TREE_R < PREV_L, error, "the folder box must end left of the preview"

; scroll bar, Amiga style: the track (where the thumb slides) from
; the first row down, then the up and down arrows together at the
; bottom. The bars are different heights, so the rows of the arrows
; and the length of the track are worked out when needed (sb_load).

SCROLL_STEP       = 3             ; lines per mouse wheel notch
                                  ; a page (Page Up/Down, or a click
                                  ;   on the track) is the list's
                                  ;   height less one line
DBLCLICK_TIME     = 30            ; two clicks within 30 jiffies (half a
                                  ; second) count as a double-click
REPEAT_DELAY      = 20            ; frames before a held click repeats
REPEAT_RATE       = 3             ; frames between repeats

FOCUS_TREE        = 0             ; what the keyboard moves in (see
FOCUS_FILES       = 1             ;   the "focus" variable): a list,
FOCUS_TEXT        = 2             ;   or the text in the preview

BAR_TREE          = 1             ; the scroll bars (see hold_bar and
BAR_FILES         = 2             ;   sb_load)
BAR_TEXT          = 3

; Key codes returned by GETIN (PETSCII, plus the X16's extra keys)
KEY_RUNSTOP       = $03
KEY_TAB           = $09
KEY_SHIFT_TAB     = $18
KEY_RETURN        = $0D
KEY_ESC           = $1B
KEY_UP            = $91
KEY_DOWN          = $11
KEY_LEFT          = $9D
KEY_RIGHT         = $1D
KEY_HOME          = $13
KEY_END           = $04
KEY_PGUP          = $82
KEY_PGDN          = $02

;------------------------------------------------------------------
; Colours
;
; In text mode every character cell has a colour byte: the high
; nibble is the background colour, the low nibble the foreground
; (text) colour. Colours are entries 0-15 of the palette. At start-
; up set_palette changes entries 6, 9, A, B, C and F to the colours
; below (9 and F are Workbench's blue and grey), and entries
; 128-255 to the logo's colours (and restore_system puts them all
; back). The others keep the X16 defaults.
;
;   0 (see below) 1 white  2 red      3 cyan     4 purple   5 green
;   6 blue*   7 yellow   8 orange   9 Amiga blue* A dk blue* B dk grey*
;   C black*  D lt green E lt blue  F Amiga grey*   (* = changed)
;
; Colour 0 is never used: in this text mode colour 0 is see-through,
; not black, so black is colour C instead.
;------------------------------------------------------------------
COL_DESKTOP       = $A1           ; white on dark blue
COL_OUT_LIGHT     = $A1           ; window's outer edge, drawn on the
COL_OUT_DARK      = $AC           ;   desktop: white / black
COL_LIGHT         = $F1           ; light edge: white on grey
COL_DARK          = $FC           ; dark edge: black on grey
COL_FRAME         = $FC           ; scroll bars: black on grey
COL_TITLE         = $9C           ; title bar: black on Amiga blue
COL_LABEL         = $FC           ; black on grey
COL_LIST          = $FC           ; list rows: black on grey
COL_FILE          = $FC           ; picture or text file (they can be
                                  ;   previewed): black on grey
COL_OTHER         = $FB           ; any other file (nothing to do
                                  ;   with it): dark grey on grey
COL_PRG           = $F6           ; program: medium-dark blue on grey
COL_SEL           = $9C           ; selected item: black on blue
COL_SEL_PRG       = $91           ; selected program: white on blue
COL_SEL_DIM       = $B1           ; selected item in the list without
                                  ;   the keyboard focus: white on
                                  ;   dark grey
COL_FOLDER        = $08           ; folder icon foreground: orange
COL_EMPTY         = $FB           ; "(no files)": dark grey on grey
COL_ERROR         = $F2           ; error in a list: red on grey
COL_STATUS        = $FC           ; status line: black on grey
COL_STATUS_ERR    = $F2           ; error on status line: red

;------------------------------------------------------------------
; Custom characters
;
; We use the "upper/lower case" character set so file names can be
; shown in mixed case. At start-up our own 8x8 shapes (see "glyphs"
; in SCREEN.ASM) are drawn over screen codes $80-$93, which are
; normally reverse-video letters that this program never uses.
;------------------------------------------------------------------
GLYPH_BASE        = $80           ; first replaced screen code

; Edges. Each cell can only have two colours, but where a white edge
; meets a black one a corner would need three (white, black and the
; grey inside). So the edges are thin lines along one side of a
; cell, and each line is drawn in whichever cell lets it use just
; one colour; the same shapes are used in white and in black.
CH_E_R            = $80           ; line down the right-hand side
CH_E_L            = $81           ; line down the left-hand side
CH_E_B            = $82           ; line along the bottom
CH_E_T            = $83           ; line along the top
CH_C_BR           = $84           ; one dot in the bottom right corner
CH_C_BL           = $85           ; one dot in the bottom left corner
CH_C_TR           = $86           ; one dot in the top right corner
CH_C_TL           = $87           ; one dot in the top left corner
; title bar gadgets, each 2 characters wide
CH_CLOSE          = $88           ; $88-$89 close gadget
CH_ZOOM           = $8A           ; $8A-$8B zoom gadget
CH_DEPTH          = $8C           ; $8C-$8D depth gadget
; scroll bar
CH_SB_UP          = $8E           ; up arrow button
CH_SB_DOWN        = $8F           ; down arrow button
CH_SB_THUMB       = $90           ; the thumb
CH_SB_TRACK       = CH_E_L        ; empty track: just a line down the
                                  ;   left, between it and the list
; tree
CH_FOLDER         = $91           ; folder icon
CH_PLUS           = $92           ; [+] box
CH_MINUS          = $93           ; [-] box
; ASCII characters that the PETSCII character set doesn't have (it
; has a pound sign and arrows in their places), needed for text
; files and file names
CH_BSLASH         = $94           ; \
CH_CARET          = $95           ; ^
CH_USCORE         = $96           ; _
CH_BTICK          = $97           ; `
CH_LBRACE         = $98           ; {
CH_VBAR           = $99           ; |
CH_RBRACE         = $9A           ; }
CH_TILDE          = $9B           ; ~

GLYPH_COUNT       = $9C - GLYPH_BASE ; number of custom characters

;------------------------------------------------------------------
; Zero page variables. Only zero page locations can be used as
; pointers with the (zp),Y addressing mode, so pointers live here.
;------------------------------------------------------------------
.segment "ZEROPAGE"
ptr:              .res 2          ; points at a record in banked RAM
sptr:             .res 2          ; points at a string to print
optr:             .res 2          ; points at the order array to sort
mouse_x:          .res 2          ; mouse position in pixels, filled
mouse_y:          .res 2          ;   in by the KERNAL's MOUSE_GET

;------------------------------------------------------------------
; Other variables (BSS = uninitialised memory after the program)
;------------------------------------------------------------------
.segment "BSS"
cur_color:        .res 1          ; colour used by put_char
remain:           .res 1          ; characters left in the field being
                                  ;   drawn (stops long names spilling
                                  ;   into the next column)
fill_n:           .res 1          ; count for hfill / vfill
tmp:              .res 4          ; scratch bytes

tree_count:       .res 1          ; number of nodes in the tree
tree_sel:         .res 1          ; node of the folder that is open
tree_scroll:      .res 1          ; first node shown at the top
file_count:       .res 1          ; number of files in the folder
file_sel:         .res 1          ; highlighted file ($FF = none)
file_scroll:      .res 1          ; first file shown at the top
tdir_count:       .res 1          ; sub-folders found by read_dir

buttons:          .res 1          ; mouse buttons this frame
prev_buttons:     .res 1          ; mouse buttons last frame
wheel:            .res 1          ; mouse wheel movement this frame
click_col:        .res 1          ; mouse position in text columns
click_row:        .res 1          ;   and rows (pixels / 8)
last_click_idx:   .res 1          ; file clicked last time ($FF = none)
last_click_time:  .res 1          ; clock value at that click

hold_bar:         .res 1          ; scroll bar being held: 0 = none,
                                  ;   or BAR_TREE/BAR_FILES/BAR_TEXT
hold_drag:        .res 1          ; not 0 while dragging the thumb
hold_timer:       .res 1          ; frames until the next repeat
sb_first:         .res 1          ; not 0 for the first click of a hold
; scroll bar maths (see sb_load). Counts and positions are 16-bit
; because a text file can have more than 255 lines.
sb_bar:           .res 1          ; which bar sb_load loaded
sb_count:         .res 2          ; lines in its list
sb_scroll:        .res 2          ; its scroll position (top line)
sb_new:           .res 2          ; a new scroll position
sb_max:           .res 2          ; the largest scroll position
sb_rows:          .res 1          ; rows the list shows
sb_top:           .res 1          ; screen row of its first line
sb_track:         .res 1          ; rows in its scroll bar's track
sb_up_row:        .res 1          ; screen rows of its scroll bar's
sb_down_row:      .res 1          ;   up and down arrows
mul_a:            .res 1          ; multiply / divide workspace
mul_b:            .res 1
mul_lo:           .res 1
mul_hi:           .res 1
div_d:            .res 1

dir_error:        .res 1          ; not 0 if the folder couldn't be read
focus:            .res 1          ; FOCUS_TREE, FOCUS_FILES or
                                  ;   FOCUS_TEXT
key_delta:        .res 1          ; how far a key moves the selection

file_order:       .res MAX_FILES  ; record numbers of the files, in
                                  ;   sorted order (in groups, see
                                  ;   compare_names in TREE.ASM)
tdir_order:       .res MAX_TDIRS  ; same for the sub-folders
recbuf:           .res 64         ; a copy of one record in normal RAM
linebuf:          .res 256        ; one line of a directory listing
namebuf:          .res 64         ; the name found in that line
namelen:          .res 1          ; its length
cmdbuf:           .res 80         ; a DOS command being sent
cmdlen:           .res 1          ; its length
dos_status:       .res 2          ; first two digits of the DOS reply
pathbuf:          .res 256        ; "/GAMES/ARCADE" for the status line
chain:            .res MAX_DEPTH+1 ; nodes from the root down to the
                                  ;   folder being opened
pal_save:         .res 512        ; the original palette (256 colours,
                                  ;   2 bytes each)

;------------------------------------------------------------------
.segment "CODE"

;==================================================================
; Program start
;==================================================================
start:
   jsr init_screen                ; text mode, palette, glyphs, desktop
   jsr show_logo                  ; the Commander X16 logo sprites
   jsr draw_window                ; the window and its empty boxes
   jsr preview_init               ; layer 0 for the preview picture

   ; Turn the mouse pointer on. SCREEN_MODE with carry set returns
   ; the screen size in X and Y, which is what MOUSE_CONFIG wants.
   ; A = 1 means "show the default arrow pointer".
   sec
   jsr SCREEN_MODE
   lda #1
   jsr MOUSE_CONFIG

   ; The tree starts with just one node, the root folder.
   jsr tree_init
   stz tree_scroll
   stz prev_buttons
   stz hold_bar
   lda #FOCUS_TREE                ; the keyboard starts in the tree
   sta focus
   lda #$FF                       ; no file clicked yet
   sta last_click_idx

   ; Open the root folder: lists its files and shows its sub-folders.
   lda #0
   jsr select_node

;==================================================================
; Main loop
;
; Runs once per video frame (60 times a second). WAI sleeps until
; the next interrupt; the KERNAL's interrupt handler reads the mouse
; and keyboard for us, so we only need to look at the results.
;==================================================================
main_loop:
   wai

   ; Keyboard. GETIN returns 0 if no key was pressed. (Holding a
   ; key down repeats it, so holding Down keeps moving.)
   jsr GETIN
   beq :+
   jsr handle_key
:

   ; Mouse: MOUSE_GET writes the position to the 4 zero page bytes
   ; whose address is in X, returns the buttons in A (bit 0 = left)
   ; and the wheel movement in X.
   ldx #mouse_x
   jsr MOUSE_GET
   sta buttons
   stx wheel

   ; Convert pixels to text cells: divide the 16-bit position by 8.
   ; The first LSR/ROR pair shifts the high byte's low bit into the
   ; low byte; two more shifts complete the divide by 8.
   lda mouse_x+1
   lsr
   lda mouse_x
   ror
   lsr
   lsr
   sta click_col                  ; 0..79
   lda mouse_y+1
   lsr
   lda mouse_y
   ror
   lsr
   lsr
   sta click_row                  ; 0..59

   lda wheel                      ; wheel moved?
   beq @no_wheel
   jsr handle_wheel
@no_wheel:

   ; Left button. Three cases:
   ;   up now                 -> stop any scroll bar hold
   ;   down now, up before    -> a new click
   ;   down now, down before  -> still held (repeat or drag)
   lda buttons
   and #1
   beq @released
   lda prev_buttons
   and #1
   bne @held
   jsr handle_click
   bra @buttons_done
@held:
   jsr handle_hold
   bra @buttons_done
@released:
   stz hold_bar
@buttons_done:
   lda buttons
   sta prev_buttons

   ; the preview picture: decode it once the selection has stayed
   ; the same for a moment (see PNG.ASM)
   jsr preview_tick
   jmp main_loop

;------------------------------------------------------------------
; quit - restore the normal screen and go back to BASIC's READY.
; ENTER_BASIC with carry clear is a "warm start": it keeps whatever
; is in BASIC memory.
;------------------------------------------------------------------
quit:
   jsr restore_system
   clc
   jmp ENTER_BASIC

;------------------------------------------------------------------
; handle_click - the left button was pressed at click_col/click_row.
; Works out what was clicked and passes it on to tree_click,
; file_click or sb_click.
;------------------------------------------------------------------
handle_click:
   ; ignore clicks above the lists
   lda click_row
   sec
   sbc #LIST_TOP
   bcc @done
   sta tmp                        ; row within the list

   ; which list? The lists are different heights, so the row is
   ; checked against the height of the one under the pointer.
   lda click_col
   cmp #TREE_X
   bcc @done                      ; left of the tree
   cmp #FILE_X
   bcs @file_col                  ; right of the gap: the file list
   ldx tmp
   cpx #TREE_ROWS
   bcs @done                      ; below the folder list
   cmp #TREE_X+TREE_W
   bcc @tree                      ; on a folder name
   cmp #TREE_SB
   beq @tree_sb                   ; on the tree's scroll bar
   rts                            ; (on the gap between the boxes)
@file_col:
   ldx tmp
   cpx #FILE_ROWS
   bcs @preview                   ; below the file list
   cmp #FILE_X+FILE_W
   bcc @files                     ; on a file name
   cmp #FILE_SB
   beq @file_sb                   ; on the files' scroll bar
@done:                            ; anywhere else: nothing to do
   rts

@preview:                         ; on the preview: only text (see
   ldx pv_text                    ;   TEXT.ASM) reacts to clicks
   beq @done
   ldx click_row
   cpx #PREV_TOP
   bcc @done                      ; above it ("Preview:" label)
   cpx #PREV_TOP+PREV_ROWS
   bcs @done                      ; below it
   cmp #TXT_SB
   bcc @text                      ; on the text
   bne @done                      ; right of it
   lda #BAR_TEXT                  ; on the text's scroll bar
   jmp sb_click
@text:
   lda #FOCUS_TEXT                ; clicking the text gives it the
   jmp set_focus                  ;   keyboard focus

@tree:
   ; node number = list row + scroll position (if there is one)
   lda tmp
   clc
   adc tree_scroll
   bcs @done
   cmp tree_count
   bcs @done                      ; empty row below the last node
   jmp tree_click

@files:
   ; position in the sorted file list = list row + scroll position
   lda tmp
   clc
   adc file_scroll
   bcs @done
   cmp file_count
   bcs @done                      ; empty row below the last file
   jmp file_click

@tree_sb:
   lda #BAR_TREE
   jmp sb_click
@file_sb:
   lda #BAR_FILES
   jmp sb_click

; handle_wheel - scroll the list (or text) under the mouse pointer.
; The wheel value is negative when rolled away from you (scroll up)
; and positive when rolled towards you (scroll down).
;------------------------------------------------------------------
handle_wheel:
   ldy #SCROLL_STEP               ; down
   lda wheel
   bpl :+
   ldy #256-SCROLL_STEP           ; up (negative number)
:  tya
   ldx click_col
   cpx #TREE_R+1
   bcs :+
   ldx #BAR_TREE                  ; pointer is over the tree
   bra scroll_bar
:  cpx #FILE_R+1
   bcs @done                      ; right of the file list
   ldx click_row
   cpx #FILE_BOX_B+1
   bcs :+
   ldx #BAR_FILES                 ; pointer is over the files
   bra scroll_bar
:  ldx pv_text                    ; over the preview: scroll it if it
   beq @done                      ;   shows text
   ldx #BAR_TEXT
   bra scroll_bar
@done:
   rts

;------------------------------------------------------------------
; scroll_bar - scroll bar X's list by A lines (negative = up),
; redrawing it if the position changed
;------------------------------------------------------------------
scroll_bar:
   pha
   jsr sb_load
   pla
   jsr calc_scroll                ; sb_new = the new position
   ; fall through

;------------------------------------------------------------------
; sb_apply - scroll the list of bar sb_bar to position sb_new
; (redrawing it if that is a change)
;------------------------------------------------------------------
sb_apply:
   lda sb_bar
   cmp #BAR_TREE
   bne @files
   lda sb_new
   cmp tree_scroll
   beq @same                      ; no change: nothing to redraw
   sta tree_scroll
   jmp draw_tree
@files:
   cmp #BAR_FILES
   bne @text
   lda sb_new
   cmp file_scroll
   beq @same
   sta file_scroll
   jmp draw_files
@text:
   jmp text_set_scroll            ; (see TEXT.ASM)
@same:
   rts

;------------------------------------------------------------------
; calc_scroll - work out a new scroll position
; In:  A = lines to move (signed: $FD = -3), and sb_load done
; Out: sb_new = sb_scroll + A, kept between 0 and sb_max (the last
;      position that still fills the list)
;------------------------------------------------------------------
calc_scroll:
   ldx #0                         ; X = high byte of the movement:
   cmp #$80                       ;   0, or $FF if it is negative
   bcc :+
   dex
:  clc
   adc sb_scroll
   sta sb_new
   txa
   adc sb_scroll+1
   sta sb_new+1
   bmi @zero                      ; went below 0
   lda sb_max                     ; past the largest position?
   cmp sb_new
   lda sb_max+1
   sbc sb_new+1
   bcs @done                      ; no (sb_max >= sb_new)
   lda sb_max
   sta sb_new
   lda sb_max+1
   sta sb_new+1
@done:
   rts
@zero:
   stz sb_new
   stz sb_new+1
   rts

;==================================================================
; Keyboard
;
; The keyboard works on one list at a time, the one with the
; "focus" (focus = FOCUS_TREE or FOCUS_FILES). Its highlight bar is
; blue; the other list's is dark grey.
;
;   Tab, Shift+Tab   move between the lists and the text preview
;   Up, Down         move the highlight one line
;   Page Up/Down     move it a page
;   Home, End        move it to the first / last item
;   Right            expand the open folder and open its first
;                    sub-folder
;   Left             open the open folder's parent
;                    (Left and Right work in either list)
;   RETURN           folders: go to the file list
;                    files:   run the highlighted program
;   Q, ESC, RUN/STOP quit
;
; In the folder list the highlight is the open folder, so moving it
; opens a folder, like clicking one, except that it isn't expanded:
; Down goes to the next folder down the list, not into this one.
;==================================================================

;------------------------------------------------------------------
; handle_key - act on the key in A
;------------------------------------------------------------------
handle_key:
   cmp #KEY_ESC
   beq @quit
   cmp #KEY_RUNSTOP
   beq @quit
   tax
   and #$7F                       ; q and Q differ only in bit 7
   cmp #$51                       ; 'Q'
   beq @quit
   txa

   ; look the key up in key_codes; the matching entry in key_jumps
   ; is the routine that handles it
   ldx #0
@find:
   cmp key_codes,x
   beq @found
   inx
   cpx #key_codes_end-key_codes
   bne @find
   rts                            ; not one of ours: ignore it
@found:
   txa
   asl                            ; 2 bytes per address
   tax
   jmp (key_jumps,x)              ; 65C02: jump to the address in
                                  ;   the table at key_jumps + X
@quit:
   jmp quit

key_codes:
   .byte KEY_TAB, KEY_SHIFT_TAB, KEY_UP, KEY_DOWN, KEY_PGUP
   .byte KEY_PGDN, KEY_HOME, KEY_END, KEY_LEFT, KEY_RIGHT
   .byte KEY_RETURN
key_codes_end:
key_jumps:
   .word key_tab, key_backtab, key_up, key_down, key_pgup
   .word key_pgdn, key_home, key_end, key_left, key_right
   .word key_return

;------------------------------------------------------------------
; key_tab     - move the focus on: folders -> files -> text -> folders
; key_backtab - Shift+Tab, the other way round
; The text is skipped unless the preview is showing a text file.
;------------------------------------------------------------------
key_tab:
   ldx focus
   lda tab_next,x
   cmp #FOCUS_TEXT
   bne @go
   ldx pv_text
   bne @go
   lda #FOCUS_TREE                ; no text: on to the folders
@go:
   jmp set_focus

key_backtab:
   ldx focus
   lda tab_prev,x
   cmp #FOCUS_TEXT
   bne @go
   ldx pv_text
   bne @go
   lda #FOCUS_FILES               ; no text: back to the files
@go:
   jmp set_focus

tab_next: .byte FOCUS_FILES, FOCUS_TEXT, FOCUS_TREE ; by focus
tab_prev: .byte FOCUS_TEXT, FOCUS_TREE, FOCUS_FILES

;------------------------------------------------------------------
; key_up / key_down / key_pgup / key_pgdn - move by a line or page
;------------------------------------------------------------------
key_up:
   lda #$FF                       ; -1
   bra move_by
key_down:
   lda #1
   bra move_by
key_pgup:
   jsr focus_page                 ; A = a page in the focused list
   eor #$FF                       ; make it negative: -A = (A xor
   inc a                          ;   $FF) + 1 (two's complement)
   bra move_by
key_pgdn:
   jsr focus_page
   ; fall through

;------------------------------------------------------------------
; move_by - move the focused list's highlight by A lines (negative
; = up), stopping at the first and last items. If no file is
; highlighted yet, the top file on screen is highlighted instead.
; With the focus on the text, it scrolls the text by A lines.
;------------------------------------------------------------------
move_by:
   sta key_delta
   ldx focus
   cpx #FOCUS_TEXT
   bne :+
   ldx #BAR_TEXT
   jmp scroll_bar
:
   jsr focus_info                 ; A = highlighted item, X = count
   cpx #0
   beq @done                      ; empty list
   cmp #$FF
   bne :+
   lda file_scroll                ; nothing highlighted: start with
   bra move_to                    ;   the top file on screen
:  stx tmp                        ; tmp = count
   ldx key_delta                  ; negative?
   bmi @up
   clc                            ; down: add
   adc key_delta
   bcc move_to                    ; (move_to stops at the last item)
   lda #$FF                       ; past 255
   bra move_to
@up:
   clc                            ; up: adding a negative number
   adc key_delta                  ;   carries if still >= 0
   bcs move_to
   lda #0                         ; went above the first item
   bra move_to
@done:
   rts

;------------------------------------------------------------------
; key_home / key_end - first / last item
;------------------------------------------------------------------
key_home:
   lda #0
   bra move_to
key_end:
   lda #$FF                       ; move_to stops at the last item
   ; fall through

;------------------------------------------------------------------
; move_to - highlight item A of the focused list (or the last item,
; if A is past the end), scrolling to keep it on screen. With the
; focus on the text, A = 0 scrolls to the top and $FF to the end.
;------------------------------------------------------------------
move_to:
   ldx focus
   cpx #FOCUS_TEXT
   bne @list
   pha
   ldx #BAR_TEXT
   jsr sb_load                    ; (sets sb_max)
   stz sb_new
   stz sb_new+1
   pla
   beq :+                         ; Home: the top
   lda sb_max                     ; End: the last position
   sta sb_new
   lda sb_max+1
   sta sb_new+1
:  jmp sb_apply
@list:
   pha
   jsr focus_info                 ; X = number of items
   pla
   cpx #0
   beq @done                      ; empty list
   stx tmp
   cmp tmp
   bcc :+                         ; A < count: fine
   txa                            ; past the end: the last item
   dec a
:  ldx focus
   bne @file
   cmp tree_sel                   ; the tree: open that folder,
   beq @done                      ;   without expanding it
   jmp open_node                  ; (it also scrolls the tree)
@file:
   sta file_sel
   lda #$FF
   sta last_click_idx             ; (forget any half double-click)
   jsr ensure_file_visible
   jmp draw_files
@done:
   rts

;------------------------------------------------------------------
; key_right  - go down a level: expand the open folder (if it is
;              collapsed) and open its first sub-folder, which is
;              left collapsed until Right is pressed again
; key_left   - go up a level: open the open folder's parent
; key_return - folders: go to the file list; files: run the
;              highlighted program
;
; In the tree a folder's sub-folders come straight after it, one
; level deeper, so its first sub-folder is node tree_sel + 1 (if
; that node is deeper than tree_sel). Its parent is the nearest node
; above it that is one level shallower.
;------------------------------------------------------------------
key_right:
   jsr leave_text
   lda tree_sel
   jsr tree_ptr
   ldy #REC_FLAGS
   lda (ptr),y
   stz RAM_BANK
   bit #FLAG_NOKIDS
   bne @done                      ; it has no sub-folders
   bit #FLAG_EXPANDED
   bne @open                      ; sub-folders already in the tree
   ldx dir_error
   bne @done                      ; its listing couldn't be read
   lda tree_sel                   ; collapsed: add them (they were
   jsr insert_children            ;   read when it was opened)
@open:
   ldx tree_sel                   ; the node after it...
   inx
   cpx tree_count
   bcs @done                      ; (end of the tree)
   lda tree_sel
   jsr node_depth
   sta tmp                        ; tmp = open folder's depth
   lda tree_sel
   inc a
   jsr node_depth
   cmp tmp
   beq @done                      ; ...must be one level deeper,
   bcc @done                      ;   or it isn't a sub-folder
   lda tree_sel
   inc a
   jmp open_node                  ; open it, still collapsed
@done:
   rts

key_left:
   jsr leave_text
   lda tree_sel
   jsr node_depth
   beq @done                      ; the root has no parent
   dec a
   sta tmp                        ; tmp = the parent's depth
   ldx tree_sel
@scan:
   dex
   phx
   txa
   jsr node_depth
   plx
   cmp tmp
   bne @scan
   txa
   jmp open_node
@done:
   rts

key_go_files:
   lda #FOCUS_FILES
   jmp set_focus

key_return:
   lda focus
   beq key_go_files               ; folders: go to the file list
   cmp #FOCUS_TEXT
   beq key_go_files               ; text: back to the file list
   ldx file_sel
   cpx #$FF
   beq @done                      ; no file highlighted
   lda file_order,x               ; is it a program?
   jsr file_ptr
   ldy #REC_FLAGS
   lda (ptr),y
   stz RAM_BANK
   and #FLAG_PRG
   beq @done                      ; no: nothing to run
   lda file_sel
   jmp launch_file                ; doesn't come back if it works
@done:
   rts

;------------------------------------------------------------------
; focus_info - about the focused list
; Out: A = highlighted item ($FF = none), X = number of items
;------------------------------------------------------------------
focus_info:
   lda focus
   bne :+
   lda tree_sel
   ldx tree_count
   rts
:  lda file_sel
   ldx file_count
   rts

;------------------------------------------------------------------
; focus_page - A = how far Page Up/Down move in the focused list:
; its height less one line, so the line at the edge stays in view
;------------------------------------------------------------------
focus_page:
   ldx focus
   lda focus_pages,x
   rts
focus_pages: .byte TREE_ROWS-1, FILE_ROWS-1, PREV_ROWS-1 ; by focus

;------------------------------------------------------------------
; leave_text - if the text has the keyboard focus, move it to the
; file list (without redrawing). Left and Right change folder,
; which clears the text preview, so they use this first.
;------------------------------------------------------------------
leave_text:
   lda focus
   cmp #FOCUS_TEXT
   bne :+
   lda #FOCUS_FILES
   sta focus
:  rts

;------------------------------------------------------------------
; set_focus - give the keyboard focus to A (FOCUS_TREE, FOCUS_FILES
; or FOCUS_TEXT), and redraw both lists so the highlight bars show
; which one has it (with the text, both are dimmed). Going to the file list highlights the top file
; on screen if none is highlighted yet.
;------------------------------------------------------------------
set_focus:
   cmp focus
   beq @done                      ; no change
   sta focus
   cmp #FOCUS_FILES
   bne @draw
   lda file_sel
   cmp #$FF
   bne @draw                      ; a file is already highlighted
   lda file_count
   beq @draw                      ; no files
   lda file_scroll
   sta file_sel
@draw:
   jsr draw_tree
   jmp draw_files
@done:
   rts

;------------------------------------------------------------------
; ensure_file_visible - scroll the file list, if needed, so the
; highlighted file (file_sel) is on screen. (Doesn't redraw.)
;------------------------------------------------------------------
ensure_file_visible:
   lda file_sel
   cmp file_scroll
   bcs :+
   sta file_scroll                ; above the top: make it the top row
   rts
:  sec
   sbc file_scroll                ; rows below the top
   cmp #FILE_ROWS
   bcc :+                         ; on screen: nothing to do
   lda file_sel                   ; below the bottom: make it the
   sec                            ;   bottom row
   sbc #FILE_ROWS-1
   sta file_scroll
:  rts

;==================================================================
; Scroll bars
;
; A scroll bar is one column: an up arrow on the first list row, a
; down arrow on the last, and the track in between, where the thumb
; shows how far down the list is scrolled.
;
;   click an arrow        scroll one line
;   click above the thumb scroll up a page
;   click below the thumb scroll down a page
;   hold the button       repeat (after REPEAT_DELAY frames)
;   press on the thumb    drag it; the list follows the pointer
;
; The bars are numbered 1 (tree) and 2 (files).
;==================================================================

;------------------------------------------------------------------
; sb_click - the button went down on a scroll bar
; In: A = bar number, click_row = where
;------------------------------------------------------------------
sb_click:
   sta hold_bar                   ; remember it for handle_hold
   stz hold_drag
   lda #REPEAT_DELAY
   sta hold_timer
   lda #1
   sta sb_first
   jmp sb_action

;------------------------------------------------------------------
; handle_hold - the button is still down. Repeat the scroll bar
; action now and then, or follow the pointer when dragging.
;------------------------------------------------------------------
handle_hold:
   lda hold_bar
   beq @done                      ; not holding a scroll bar
   lda hold_drag
   bne sb_drag
   dec hold_timer
   bne @done
   lda #REPEAT_RATE               ; time for a repeat
   sta hold_timer
   stz sb_first                   ; (a repeat never starts a drag)
   jmp sb_action
@done:
   rts

;------------------------------------------------------------------
; sb_action - act on a click at click_row on scroll bar hold_bar
;------------------------------------------------------------------
sb_action:
   ldx hold_bar                   ; the bar's list, and where its
   jsr sb_load                    ;   arrows and track are
   lda click_row
   cmp sb_up_row
   beq @line_up                   ; up arrow
   cmp sb_down_row
   beq @line_down                 ; down arrow
   cmp sb_top
   bcc @done                      ; (pointer moved above the bar)
   cmp sb_up_row
   bcs @done                      ; (pointer moved below the bar)

   ; on the track: compare with the thumb's row
   jsr thumb_row
   bcs @done                      ; list doesn't scroll: no thumb
   cmp click_row
   beq @on_thumb
   bcc @page_down                 ; thumb is above the pointer
   lda sb_rows                    ; thumb is below: page up by
   eor #$FF                       ;   -(rows-1) = 1 - rows, and
   inc a                          ;   -rows = (rows xor $FF) + 1,
   inc a                          ;   so add 1 twice
   bra sb_scroll_by
@page_down:
   lda sb_rows                    ; a page = the list's height less
   dec a                          ;   one line
   bra sb_scroll_by
@on_thumb:
   lda sb_first                   ; pressing on the thumb starts a
   sta hold_drag                  ;   drag (a repeat doesn't)
@done:
   rts
@line_up:
   lda #$FF                       ; -1
   bra sb_scroll_by
@line_down:
   lda #1
   ; fall through

; sb_scroll_by - scroll the held bar's list by A lines
sb_scroll_by:
   ldx hold_bar
   jmp scroll_bar

;------------------------------------------------------------------
; sb_drag - dragging the thumb: scroll so the thumb is under the
; pointer.  position = row on track * largest position / (rows-1)
; (16-bit sums, with mul16 and div32 from PNG.ASM)
;------------------------------------------------------------------
sb_drag:
   ldx hold_bar
   jsr sb_load
   lda sb_max
   ora sb_max+1
   beq @done                      ; list doesn't scroll

   ; pointer's row on the track, kept inside the track
   lda click_row
   sec
   sbc sb_top
   bcs :+
   lda #0                         ; above the track
:  cmp sb_track
   bcc :+
   lda sb_track                   ; below the track: its last row
   dec a
:
   ; (row * largest + half a step) / (track rows - 1), rounded
   sta m_a
   stz m_a+1
   lda sb_max
   sta m_b
   lda sb_max+1
   sta m_b+1
   jsr mul16                      ; m32 = row * largest
   ldx #3
:  lda m32,x
   sta d_num,x
   dex
   bpl :-
   lda sb_track
   dec a
   sta d_div                      ; d_div = track rows - 1
   stz d_div+1
   jsr add_half_div               ; (so the answer is rounded)
   jsr div32
   lda d_num
   sta sb_new
   lda d_num+1
   sta sb_new+1
   jmp sb_apply
@done:
   rts

;------------------------------------------------------------------
; sb_load - load scroll bar X's numbers: its list's length, scroll
; position, height and first row, and from those where the bar's
; parts go and the largest scroll position.
; Out: sb_bar, sb_count, sb_scroll, sb_rows, sb_top, sb_track,
;      sb_up_row, sb_down_row, sb_max
;------------------------------------------------------------------
sb_load:
   stx sb_bar
   stz sb_count+1                 ; (the lists' numbers are 8-bit)
   stz sb_scroll+1
   lda #LIST_TOP
   sta sb_top
   cpx #BAR_TREE
   bne @files
   lda tree_count
   sta sb_count
   lda tree_scroll
   sta sb_scroll
   lda #TREE_ROWS
   bra @rows
@files:
   cpx #BAR_FILES
   bne @text
   lda file_count
   sta sb_count
   lda file_scroll
   sta sb_scroll
   lda #FILE_ROWS
   bra @rows
@text:                            ; the text preview (TEXT.ASM)
   lda t_lines
   sta sb_count
   lda t_lines+1
   sta sb_count+1
   lda t_top
   sta sb_scroll
   lda t_top+1
   sta sb_scroll+1
   lda #PREV_TOP
   sta sb_top
   lda #PREV_ROWS
@rows:
   sta sb_rows

   ; the track takes all but the last two rows, which hold the up
   ; and down arrows
   sec
   sbc #2
   sta sb_track                   ; rows - 2
   clc
   adc sb_top
   sta sb_up_row                  ; top + rows - 2
   inc a
   sta sb_down_row                ; top + rows - 1

   ; largest scroll position = count - rows (0 if it all fits)
   lda sb_count
   sec
   sbc sb_rows
   sta sb_max
   lda sb_count+1
   sbc #0
   sta sb_max+1
   bcs :+
   stz sb_max
   stz sb_max+1
:  rts

;------------------------------------------------------------------
; thumb_row - which screen row the thumb is on
; In:  sb_load done
; Out: C = 1 if the list is too short to scroll (no thumb), else
;      C = 0 and A = sb_top + scroll * (track rows - 1) / largest
;------------------------------------------------------------------
thumb_row:
   lda sb_max
   ora sb_max+1
   beq @none
   lda sb_scroll                  ; m32 = scroll * (track rows - 1)
   sta m_a
   lda sb_scroll+1
   sta m_a+1
   lda sb_track
   dec a
   sta m_b
   stz m_b+1
   jsr mul16
   ldx #3                         ;   / largest
:  lda m32,x
   sta d_num,x
   dex
   bpl :-
   lda sb_max
   sta d_div
   lda sb_max+1
   sta d_div+1
   jsr div32
   lda d_num
   clc
   adc sb_top
   clc
   rts
@none:
   sec
   rts

;------------------------------------------------------------------
; mul8 - multiply: mul_hi:mul_lo = A * X
; Works like long multiplication in binary: for each bit of A, from
; the top, double the result and add X if the bit is 1.
;------------------------------------------------------------------
mul8:
   sta mul_a
   stx mul_b
   stz mul_lo
   stz mul_hi
   ldx #8
@loop:
   asl mul_lo                     ; result * 2
   rol mul_hi
   asl mul_a                      ; next bit of A into carry
   bcc @next
   clc
   lda mul_lo                     ; bit was 1: result + X
   adc mul_b
   sta mul_lo
   bcc @next
   inc mul_hi
@next:
   dex
   bne @loop
   rts

;------------------------------------------------------------------
; div16_8 - divide: A = mul_hi:mul_lo / A
; The answer must fit in 8 bits (mul_hi less than the divisor),
; which is always true for the scroll bar sums. Works like long
; division in binary: shift the number left a bit at a time into
; A; whenever A is at least the divisor, subtract it and set that
; bit of the answer (which builds up in mul_lo as it shifts out).
;------------------------------------------------------------------
div16_8:
   sta div_d
   ldx #8
   lda mul_hi
@loop:
   asl mul_lo                     ; next bit into A
   rol a
   bcs @sub                       ; 9th bit set: certainly big enough
   cmp div_d
   bcc @next                      ; too small
@sub:
   sbc div_d                      ; (carry is set here)
   inc mul_lo                     ; answer bit = 1
@next:
   dex
   bne @loop
   lda mul_lo
   rts

;==================================================================
; Clicking in the lists
;==================================================================

;------------------------------------------------------------------
; file_click - a file was clicked
; In: A = position in the sorted file list
;
; The first click highlights the file. A second click on the same
; file within DBLCLICK_TIME is a double-click, which runs it if it's
; a program. Time comes from the KERNAL's jiffy clock (60 per second);
; only the low byte is needed because we subtract the two times.
;------------------------------------------------------------------
file_click:
   pha                            ; clicking a list gives it the
   lda #FOCUS_FILES               ;   keyboard focus
   jsr set_focus
   pla
   sta tmp+3                      ; tmp+3 = file position
   jsr RDTIM                      ; A = jiffy clock low byte
   sta tmp+2                      ; tmp+2 = time now

   lda tmp+3
   cmp last_click_idx
   bne @single                    ; a different file than last time
   lda tmp+2
   sec
   sbc last_click_time            ; time since the last click
   cmp #DBLCLICK_TIME
   bcs @single                    ; too slow for a double-click

   ; Double-click. Forget the click so a third click doesn't count,
   ; then look at the file's flags to see if it is a program.
   lda #$FF
   sta last_click_idx
   ldx tmp+3
   lda file_order,x               ; record number of this file
   jsr file_ptr                   ; ptr -> record in banked RAM
   ldy #REC_FLAGS
   lda (ptr),y
   stz RAM_BANK                   ; back to bank 0 for the KERNAL
   and #FLAG_PRG
   beq @done                      ; not a program: do nothing
   lda tmp+3
   jmp launch_file                ; doesn't come back if it works

@single:
   ; Single click: remember it and highlight the file.
   lda tmp+3
   sta last_click_idx
   sta file_sel
   lda tmp+2
   sta last_click_time
   jsr draw_files
@done:
   rts

;------------------------------------------------------------------
; tree_click - a folder in the tree was clicked
; In: A = tree node
;
;   Click on the [+]/[-] box: expand or collapse that folder.
;   Click anywhere else:      open the folder (shows its files, and
;                             expands it the first time).
;------------------------------------------------------------------
tree_click:
   pha                            ; clicking a list gives it the
   lda #FOCUS_TREE                ;   keyboard focus
   jsr set_focus
   pla
   sta tmp+3                      ; tmp+3 = node
   jsr tree_ptr                   ; ptr -> node's record
   ldy #REC_DEPTH
   lda (ptr),y
   ldy #REC_FLAGS
   tax                            ; X = depth
   lda (ptr),y
   sta tmp+2                      ; tmp+2 = flags
   stz RAM_BANK

   ; The box is drawn one column further right for each level of
   ; depth (up to 10 levels), so box column = TREE_X + min(depth,10).
   cpx #11
   bcc :+
   ldx #10
:  txa
   clc
   adc #TREE_X
   cmp click_col
   bne @select                    ; not on the box

   ; Clicked the box.
   lda tmp+2
   and #FLAG_EXPANDED
   bne @collapse                  ; expanded -> collapse it
   lda tmp+3
   cmp tree_sel
   bne @select                    ; opening a folder expands it
   jsr insert_children            ; it's the open folder: its sub-
   jmp draw_tree                  ; folders were read when it opened
@collapse:
   lda tmp+3
   jmp collapse_node

@select:
   lda tmp+3
   cmp tree_sel
   beq @done                      ; already the open folder
   jmp select_node
@done:
   rts

;------------------------------------------------------------------
; select_node - open a folder and expand it
; open_node   - open a folder but leave it collapsed (the keyboard
;               uses this, so Down steps to the next folder instead
;               of into the sub-folders; Right expands it)
; In: A = tree node
;
; Changes the DOS current directory to that folder, reads its
; listing, adds its sub-folders to the tree if they aren't shown yet
; (select_node only), then redraws the tree, file list and path.
;------------------------------------------------------------------
open_node:
   sta tree_sel
   jsr goto_node                  ; DOS "CD" to the folder
   jsr read_dir                   ; read its files and sub-folders
   bra open_common

select_node:
   sta tree_sel
   jsr goto_node                  ; DOS "CD" to the folder
   jsr read_dir                   ; read its files and sub-folders

   ; expand the node unless it is already expanded (or unreadable)
   lda tree_sel
   jsr tree_ptr
   ldy #REC_FLAGS
   lda (ptr),y
   stz RAM_BANK
   and #FLAG_EXPANDED
   bne :+
   lda dir_error
   bne :+
   lda tree_sel
   jsr insert_children
:
open_common:
   ; new folder: file list back at the top, and no file highlighted
   ; unless the keyboard is in the file list, when the first file
   ; is highlighted so Up and Down carry on working
   lda #$FF
   sta file_sel
   sta last_click_idx
   stz file_scroll
   lda focus
   cmp #FOCUS_FILES
   bne :+
   lda file_count
   beq :+
   stz file_sel
:
   jsr ensure_tree_visible
   jsr draw_tree
   jsr draw_files
   jmp draw_status

;------------------------------------------------------------------
; ensure_tree_visible - scroll the tree, if needed, so the open
; folder (tree_sel) is on screen.
;------------------------------------------------------------------
ensure_tree_visible:
   lda tree_sel
   cmp tree_scroll
   bcs :+
   sta tree_scroll                ; above the top: make it the top row
   rts
:  sec
   sbc tree_scroll                ; rows below the top
   cmp #TREE_ROWS
   bcc :+                         ; on screen: nothing to do
   lda tree_sel                   ; below the bottom: make it the
   sec                            ;   bottom row
   sbc #TREE_ROWS-1
   sta tree_scroll
:  rts

;------------------------------------------------------------------
; restore_system - put things back the way BASIC expects them:
; mouse pointer and logo sprites off, the original palette, RAM bank
; 0, default I/O channels, and SCINIT (the KERNAL's CINT) resets the
; screen mode, colours and character set, and clears the screen.
;------------------------------------------------------------------
restore_system:
   lda #0
   ldx #0
   ldy #0
   jsr MOUSE_CONFIG               ; A = 0: hide the mouse pointer
   jsr hide_logo
   jsr preview_off
   jsr restore_palette
   stz RAM_BANK
   jsr CLRCHN
   jmp SCINIT

;------------------------------------------------------------------
; The rest of the program
;------------------------------------------------------------------
.include "SCREEN.ASM"
.include "TREE.ASM"
.include "DOS.ASM"
.include "LAUNCH.ASM"
.include "PNG.ASM"
.include "TEXT.ASM"
