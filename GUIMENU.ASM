;******************************************************************
; X16 GUI Menu
;
; A mouse driven program launcher for the Commander X16, styled
; after a Windows 3.1 window on a dark blue desktop.
;
;   [logo]  COMMANDER X16                      <- desktop icon, with
;                                                   the name in big
;                                                   letters beside it
;  +==========================================================+
;  |[-]            SD Card Program Launcher             [v][^]|
;  |----------------------------------------------------------|
;  |  Folders:              Files:                 Preview:   |
;  |  +---------------+-+   +---------------+-+   +---------+ |
;  |  |[-] SD Card    |^|   | HELLO.PRG     |^|   |         | |
;  |  | [+] GAMES     | |   | readme.txt    |#|   |         | |
;  |  | [+] TOOLS     |v|   |               |v|   |         | |
;  |  +---------------+-+   +---------------+-+   +---------+ |
;  |  /GAMES                    Double-click a program ...     |
;  +==========================================================+
;
;   - Left list:   a tree of the folders on the SD card.
;                  Click a folder name to open it.
;                  Click its [+]/[-] box to expand or collapse it.
;   - Middle list: the files in the open folder. Programs (.PRG)
;                  are shown in blue. Double-click one to run it.
;   - Right panel: preview (empty for now).
;   - Scroll bars: click the arrows to scroll a line (hold to
;                  repeat), click the track above/below the thumb
;                  to scroll a page, or drag the thumb. The mouse
;                  wheel scrolls the list under the pointer.
;   - The window's control box and minimise/maximise buttons are
;     only decoration.
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
; there. Bank 0 is used by the KERNAL and DOS, so we use banks 1-4.
;
; Every folder name and file name is stored as a 64 byte "record",
; so one 8 KB bank holds 128 records:
;
;   byte 0     REC_DEPTH  tree nodes: how deep the folder is (root=0)
;   byte 1     REC_FLAGS  tree nodes: FLAG_EXPANDED / FLAG_NOKIDS
;                         files:      FLAG_PRG
;   bytes 2-63 REC_NAME   the name, ending with a 0 byte
;------------------------------------------------------------------
TREE_BANK         = 1             ; banks 1-2 : folder tree nodes
FILE_BANK         = 3             ; bank 3    : files in current folder
TDIR_BANK         = 4             ; bank 4    : sub-folders just read

REC_DEPTH         = 0             ; offsets inside a record
REC_FLAGS         = 1
REC_NAME          = 2
NAME_MAX          = 61            ; longest name we keep (+1 for the 0)

MAX_TREE          = 250           ; most folders the tree can show
MAX_FILES         = 128           ; most files listed for one folder
MAX_TDIRS         = 128           ; most sub-folders read for one folder
MAX_DEPTH         = 30            ; deepest folder level we will open

FLAG_EXPANDED     = $01           ; tree node's sub-folders are shown
FLAG_NOKIDS       = $02           ; tree node has no sub-folders
FLAG_PRG          = $01           ; file name ends in .PRG

;------------------------------------------------------------------
; Screen layout (80 columns x 60 rows text mode)
; Columns are numbered 0-79 from the left, rows 0-59 from the top.
;------------------------------------------------------------------
SCREEN_COLS       = 80
SCREEN_ROWS       = 60

; desktop icon
LOGO_X            = 4             ; top left corner of the 7x7 logo
LOGO_Y            = 0
BANNER_X          = 13            ; "Commander X16" in big letters
BANNER_Y          = 2             ;   beside the logo: 4 rows, 4
                                  ;   columns per letter
BANNER_MAX        = 16            ; most letters the banner can hold

; the window
WIN_L             = 1             ; left border column
WIN_R             = 78            ; right border column
WIN_T             = 9             ; top border row
WIN_B             = 58            ; bottom border row
TITLE_ROW         = 10            ; title bar
CLIENT_TOP        = 11            ; first row inside, under the title
LABEL_ROW         = 12            ; "Folders:" "Files:" "Preview:"
BOX_T             = 13            ; top edge of the list boxes
LIST_TOP          = 14            ; first row of the lists
LIST_ROWS         = 41            ; rows 14..54 show list items
BOX_B             = 55            ; bottom edge of the list boxes
STATUS_ROW        = 57            ; status line (path and hint)
STATUS_X          = 3             ; where the path starts

; the three boxes: _L/_R = left/right edge column, _X/_W = the
; columns for text, _SB = the scroll bar column
TREE_L            = 3
TREE_X            = 4             ; folder names: columns 4..27
TREE_W            = 24
TREE_SB           = 28
TREE_R            = 29
FILE_L            = 31
FILE_X            = 32            ; file names: columns 32..55
FILE_W            = 24
FILE_SB           = 56
FILE_R            = 57
PREV_L            = 59
PREV_X            = 60            ; preview: columns 60..75
PREV_W            = 16
PREV_R            = 76

; scroll bar: up arrow on the first list row, down arrow on the
; last, and the track (where the thumb slides) in between
TRACK_TOP         = LIST_TOP+1
TRACK_ROWS        = LIST_ROWS-2

SCROLL_STEP       = 3             ; lines per mouse wheel notch
PAGE_STEP         = LIST_ROWS-1   ; lines per click on the track
DBLCLICK_TIME     = 30            ; two clicks within 30 jiffies (half a
                                  ; second) count as a double-click
REPEAT_DELAY      = 20            ; frames before a held click repeats
REPEAT_RATE       = 3             ; frames between repeats

;------------------------------------------------------------------
; Colours
;
; In text mode every character cell has a colour byte: the high
; nibble is the background colour, the low nibble the foreground
; (text) colour. Colours are entries 0-15 of the palette. At start-
; up set_palette changes entries 9, A, B, C and F to the Windows 3.1
; colours below (and restore_system puts them back). The others
; keep the X16 defaults, which the logo uses.
;
;   0 (see below) 1 white  2 red      3 cyan     4 purple   5 green
;   6 blue    7 yellow   8 orange   9 navy*    A dk blue* B grey*
;   C black*  D lt green E lt blue  F lt grey*      (* = changed)
;
; Colour 0 is never used: in this text mode colour 0 is see-through,
; not black, so black is colour C instead.
;------------------------------------------------------------------
COL_DESKTOP       = $A1           ; white on dark blue
COL_FRAME         = $FC           ; black on light grey
COL_TITLE         = $91           ; white on navy
COL_LABEL         = $FC           ; black on light grey
COL_LIST          = $1C           ; black on white
COL_FILE          = $1B           ; ordinary file: grey on white
COL_PRG           = $16           ; blue on white
COL_SEL           = $91           ; selected item: white on navy
COL_SEL_PRG       = $97           ; selected program: yellow on navy
COL_FOLDER        = $08           ; folder icon foreground: orange
COL_EMPTY         = $1B           ; "(no files)": grey on white
COL_ERROR         = $12           ; error in a list: red on white
COL_STATUS        = $FC           ; status line: black on light grey
COL_STATUS_ERR    = $F2           ; error on status line: red
COL_BANNER        = $A1           ; big "Commander X16": white on
                                  ;   dark blue

;------------------------------------------------------------------
; Custom characters
;
; We use the "upper/lower case" character set so file names can be
; shown in mixed case. At start-up our own 8x8 shapes (see "glyphs"
; in SCREEN.ASM) are drawn over screen codes $80-$AF, which are
; normally reverse-video letters that this program never uses.
;------------------------------------------------------------------
GLYPH_BASE        = $80           ; first replaced screen code
                                  ; $80-$92 are the logo pieces
; window border (grey with a black line on each side)
CH_W_TL           = $93           ; corners
CH_W_TR           = $94
CH_W_BL           = $95
CH_W_BR           = $96
CH_W_H            = $97           ; top/bottom border
CH_W_V            = $98           ; left/right border
CH_W_NL           = $99           ; notches near the corners
CH_W_NR           = $9A
CH_W_NT           = $9B
CH_W_NB           = $9C
; title bar
CH_SYSBOX         = $9D           ; control-menu box
CH_MIN            = $9E           ; minimise button
CH_MAX            = $9F           ; maximise button
CH_TOPLINE        = $A0           ; black line under the title bar
; list box border (a thin black line)
CH_LB_TL          = $A1
CH_LB_T           = $A2
CH_LB_TR          = $A3
CH_LB_L           = $A4
CH_LB_R           = $A5
CH_LB_BL          = $A6
CH_LB_B           = $A7
CH_LB_BR          = $A8
; scroll bar
CH_SB_UP          = $A9           ; up arrow button
CH_SB_DOWN        = $AA           ; down arrow button
CH_SB_TRACK       = $AB           ; empty track
CH_SB_THUMB       = $AC           ; the thumb
; tree
CH_FOLDER         = $AD           ; folder icon
CH_PLUS           = $AE           ; [+] box
CH_MINUS          = $AF           ; [-] box

CH_QUAD           = $B0           ; $B0-$BF: the 16 "quadrant" blocks
                                  ;   used for the big letters (see
                                  ;   draw_banner)
GLYPH_COUNT       = $C0 - GLYPH_BASE ; number of custom characters

;------------------------------------------------------------------
; Zero page variables. Only zero page locations can be used as
; pointers with the (zp),Y addressing mode, so pointers live here.
;------------------------------------------------------------------
.segment "ZEROPAGE"
ptr:              .res 2          ; points at a record in banked RAM
ptr2:             .res 2          ; second record pointer (sorting)
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
                                  ;   1 = tree, 2 = files
hold_drag:        .res 1          ; not 0 while dragging the thumb
hold_timer:       .res 1          ; frames until the next repeat
sb_first:         .res 1          ; not 0 for the first click of a hold
sb_count:         .res 1          ; items in the list (scroll bar maths)
sb_scroll:        .res 1          ; its scroll position
mul_a:            .res 1          ; multiply / divide workspace
mul_b:            .res 1
mul_lo:           .res 1
mul_hi:           .res 1
div_d:            .res 1

dir_error:        .res 1          ; not 0 if the folder couldn't be read

file_order:       .res MAX_FILES  ; record numbers of the files, in
                                  ;   alphabetical order
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
pal_save:         .res 32         ; the original palette entries 0-15
banner_buf:       .res BANNER_MAX*8 ; font shapes of the banner's
                                  ;   letters, 8 bytes each

;------------------------------------------------------------------
.segment "CODE"

;==================================================================
; Program start
;==================================================================
start:
   jsr init_screen                ; text mode, palette, glyphs, desktop
   jsr draw_desktop_icon          ; logo and caption
   jsr draw_window                ; the window and its empty boxes

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

   ; Keyboard: Q, ESC or RUN/STOP quits. GETIN returns 0 if no key.
   jsr GETIN
   cmp #$1B                       ; ESC
   beq quit
   cmp #$03                       ; RUN/STOP
   beq quit
   and #$7F                       ; q and Q differ only in bit 7
   cmp #$51
   beq quit

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
   bra main_loop

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
   ; ignore clicks above or below the lists
   lda click_row
   cmp #LIST_TOP
   bcc @done
   cmp #LIST_TOP+LIST_ROWS
   bcs @done
   sec
   sbc #LIST_TOP
   sta tmp                        ; row within the list, 0..40

   ; which column?
   lda click_col
   cmp #TREE_X
   bcc @done                      ; left of the tree
   cmp #TREE_X+TREE_W
   bcc @tree                      ; on a folder name
   cmp #TREE_SB
   beq @tree_sb                   ; on the tree's scroll bar
   cmp #FILE_X
   bcc @done                      ; between the boxes
   cmp #FILE_X+FILE_W
   bcc @files                     ; on a file name
   cmp #FILE_SB
   beq @file_sb                   ; on the files' scroll bar
@done:                            ; anywhere else: nothing to do
   rts

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
   lda #1
   jmp sb_click
@file_sb:
   lda #2
   jmp sb_click

;------------------------------------------------------------------
; handle_wheel - scroll the list under the mouse pointer.
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
   bcc scroll_tree                ; pointer is over the tree
   cpx #FILE_R+1
   bcc scroll_files               ; pointer is over the files
   rts

;------------------------------------------------------------------
; scroll_tree / scroll_files - scroll a list by A lines (negative =
; up), redrawing it if the position changed.
; set_tree_scroll / set_file_scroll - scroll to position A.
;------------------------------------------------------------------
scroll_tree:
   ldx tree_count
   ldy tree_scroll
   jsr calc_scroll
set_tree_scroll:
   cmp tree_scroll
   beq :+                         ; no change: nothing to redraw
   sta tree_scroll
   jsr draw_tree
:  rts

scroll_files:
   ldx file_count
   ldy file_scroll
   jsr calc_scroll
set_file_scroll:
   cmp file_scroll
   beq :+
   sta file_scroll
   jsr draw_files
:  rts

;------------------------------------------------------------------
; calc_scroll - work out a new scroll position
; In:  A = lines to move (signed: $FD = -3)
;      X = number of items in the list
;      Y = current scroll position
; Out: A = new scroll position, kept between 0 and the last position
;      that still fills the list (count - LIST_ROWS).
;------------------------------------------------------------------
calc_scroll:
   sty tmp+1
   stx tmp+2
   cmp #$80                       ; bit 7 set = negative
   bcs @neg
   clc                            ; moving down
   adc tmp+1
   bcc @store                     ; no carry: no overflow
   lda #$FF                       ; went past 255: clamp
   bra @store
@neg:
   clc                            ; moving up: adding a negative number
   adc tmp+1                      ; carries if the result is still >= 0
   bcs @store
   lda #0                         ; went below 0: clamp
@store:
   sta tmp+1                      ; wanted position

   ; largest useful position = count - LIST_ROWS (0 if short list)
   lda tmp+2
   sec
   sbc #LIST_ROWS
   bcs :+
   lda #0
:  cmp tmp+1
   bcc :+                         ; largest < wanted: use largest
   lda tmp+1                      ; otherwise use wanted
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
   lda click_row
   cmp #LIST_TOP
   beq @line_up                   ; up arrow
   bcc @done                      ; (pointer moved above the bar)
   cmp #LIST_TOP+LIST_ROWS-1
   beq @line_down                 ; down arrow
   bcs @done                      ; (pointer moved below the bar)

   ; on the track: compare with the thumb's row
   jsr sb_load
   jsr thumb_row
   bcs @done                      ; list doesn't scroll: no thumb
   cmp click_row
   beq @on_thumb
   bcc @page_down                 ; thumb is above the pointer
   lda #256-PAGE_STEP             ; thumb is below: page up
   bra sb_scroll_by
@page_down:
   lda #PAGE_STEP
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
   cpx #1
   bne :+
   jmp scroll_tree
:  jmp scroll_files

;------------------------------------------------------------------
; sb_drag - dragging the thumb: scroll so the thumb is under the
; pointer.  position = row on track * largest position / (rows-1)
;------------------------------------------------------------------
sb_drag:
   jsr sb_load
   lda sb_count                   ; largest scroll position
   sec
   sbc #LIST_ROWS
   bcc @done                      ; list doesn't scroll
   beq @done
   sta div_d

   ; pointer's row on the track, kept inside the track
   lda click_row
   sec
   sbc #TRACK_TOP
   bcs :+
   lda #0                         ; above the track
:  cmp #TRACK_ROWS
   bcc :+
   lda #TRACK_ROWS-1              ; below the track
:
   ; (row * largest + half a step) / (TRACK_ROWS-1), rounded
   ldx div_d
   jsr mul8
   lda mul_lo
   clc
   adc #(TRACK_ROWS-1)/2
   sta mul_lo
   bcc :+
   inc mul_hi
:  lda #TRACK_ROWS-1
   jsr div16_8

   ldx hold_bar
   cpx #1
   bne :+
   jmp set_tree_scroll
:  jmp set_file_scroll
@done:
   rts

;------------------------------------------------------------------
; sb_load - copy the held bar's item count and scroll position into
; sb_count and sb_scroll
;------------------------------------------------------------------
sb_load:
   ldx hold_bar
   cpx #1
   bne @files
   lda tree_count
   ldy tree_scroll
   bra @store
@files:
   lda file_count
   ldy file_scroll
@store:
   sta sb_count
   sty sb_scroll
   rts

;------------------------------------------------------------------
; thumb_row - which screen row the thumb is on
; In:  sb_count, sb_scroll
; Out: C = 1 if the list is too short to scroll (no thumb), else
;      C = 0 and A = TRACK_TOP + scroll * (TRACK_ROWS-1) / largest
;------------------------------------------------------------------
thumb_row:
   lda sb_count
   sec
   sbc #LIST_ROWS                 ; largest scroll position
   bcc @none
   beq @none
   pha
   lda sb_scroll
   ldx #TRACK_ROWS-1
   jsr mul8                       ; scroll * (TRACK_ROWS-1)
   pla
   jsr div16_8                    ;   / largest
   clc
   adc #TRACK_TOP
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
; select_node - open a folder
; In: A = tree node
;
; Changes the DOS current directory to that folder, reads its
; listing, adds its sub-folders to the tree if they aren't shown yet,
; then redraws the tree, file list and path.
;------------------------------------------------------------------
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
   ; new folder: no file highlighted, file list back at the top
   lda #$FF
   sta file_sel
   sta last_click_idx
   stz file_scroll
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
   cmp #LIST_ROWS
   bcc :+                         ; on screen: nothing to do
   lda tree_sel                   ; below the bottom: make it the
   sec                            ;   bottom row
   sbc #LIST_ROWS-1
   sta tree_scroll
:  rts

;------------------------------------------------------------------
; restore_system - put things back the way BASIC expects them:
; mouse pointer off, the original palette, RAM bank 0, default I/O
; channels, and SCINIT (the KERNAL's CINT) resets the screen mode,
; colours and character set, and clears the screen.
;------------------------------------------------------------------
restore_system:
   lda #0
   ldx #0
   ldy #0
   jsr MOUSE_CONFIG               ; A = 0: hide the mouse pointer
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
