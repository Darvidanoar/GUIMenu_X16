;******************************************************************
; X16 GUI Menu
;
; A mouse driven program launcher for the Commander X16.
;
;   +-------------------------------------------------------------+
;   | [logo]  Commander X16                                        |
;   |         SD Card Program Launcher                             |
;   +- Folders ---------+- Files ----------+- Preview -------------+
;   | [-] SD Card       |  HELLO.PRG       |                       |
;   |  [+] GAMES        |  readme.txt      |   (reserved for       |
;   |  [+] TOOLS        |                  |    later)             |
;   +-------------------+------------------+-----------------------+
;   | /GAMES                       Double-click a program to run it |
;   +-------------------------------------------------------------+
;
;   - Left column:   a tree of the folders on the SD card.
;                    Click a folder name to open it.
;                    Click its [+]/[-] box to expand or collapse it.
;   - Middle column: the files in the open folder. Programs (.PRG)
;                    are shown in yellow. Double-click one to run it.
;   - Right column:  preview panel (empty for now).
;   - Mouse wheel scrolls the column under the pointer, and the
;     arrows on the column dividers scroll a page at a time.
;   - Q, ESC or RUN/STOP quits back to BASIC.
;
; Source files (all assembled together as one unit, see the
; .include lines at the bottom of this file):
;   GUIMENU.ASM  constants, variables, start-up, main loop, mouse
;   SCREEN.ASM   everything that draws on the screen, custom glyphs
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

LOGO_X            = 1             ; top left corner of the 7x7 logo
LOGO_Y            = 0
TITLE_X           = 10            ; column of "Commander X16"

WIN_TOP           = 8             ; row of the window's top border
LIST_TOP          = 9             ; first row of the lists
LIST_ROWS         = 48            ; rows 9..56 show list items
SEP_ROW           = 57            ; line above the status line
STATUS_ROW        = 58            ; current path and hint text
WIN_BOTTOM        = 59            ; window's bottom border

LEFT_X            = 0             ; left border
TREE_X            = 1             ; folder tree: columns 1..25
TREE_W            = 25
DIV1_X            = 26            ; divider between tree and files
FILE_X            = 27            ; file list: columns 27..52
FILE_W            = 26
DIV2_X            = 53            ; divider between files and preview
PREV_X            = 54            ; preview panel: columns 54..78
PREV_W            = 25
RIGHT_X           = 79            ; right border

SCROLL_STEP       = 3             ; lines per mouse wheel notch
PAGE_STEP         = 24            ; lines per click on a scroll arrow
DBLCLICK_TIME     = 30            ; two clicks within 30 jiffies (half a
                                  ; second) count as a double-click

; Colours. In text mode every character cell has a colour byte:
; the high nibble is the background colour, the low nibble is the
; foreground (text) colour. The X16 default palette is:
;   0 black   1 white   2 red     3 cyan    4 purple  5 green
;   6 blue    7 yellow  8 orange  9 brown   A lt red  B dk grey
;   C grey    D lt grn  E lt blue F lt grey
COL_SCREEN        = $61           ; white on blue
COL_BORDER        = $6E           ; light blue on blue
COL_TITLE         = $61           ; white on blue
COL_SUBTITLE      = $63           ; cyan on blue
COL_DIR           = $61           ; folder names: white on blue
COL_FILE          = $6F           ; other files: light grey on blue
COL_PRG           = $67           ; programs: yellow on blue
COL_SEL           = $E0           ; selected item: black on light blue
COL_SEL_PRG       = $70           ; selected program: black on yellow
COL_STATUS        = $6F           ; path: light grey on blue
COL_HINT          = $6C           ; hint text: grey on blue
COL_ERROR         = $6A           ; errors: light red on blue

;------------------------------------------------------------------
; Custom characters
;
; We use the "upper/lower case" character set so that file names can
; be shown in mixed case. That set has no diagonal shapes for the
; logo, so at start-up we draw our own 8x8 characters (see "glyphs"
; in SCREEN.ASM) over screen codes $80-$A2. Those codes are normally
; reverse-video letters, which this program never uses.
;------------------------------------------------------------------
GLYPH_BASE        = $80           ; first replaced screen code
                                  ; $80-$92 are the logo pieces
CH_TL             = $93           ; box drawing: top left corner
CH_TR             = $94           ; top right corner
CH_BL             = $95           ; bottom left corner
CH_BR             = $96           ; bottom right corner
CH_H              = $97           ; horizontal line
CH_V              = $98           ; vertical line
CH_LT             = $99           ; |- (left tee)
CH_RT             = $9A           ; -| (right tee)
CH_TT             = $9B           ; T  (top tee)
CH_BT             = $9C           ; upside-down T (bottom tee)
CH_UP             = $9E           ; scroll up arrow
CH_DOWN           = $9F           ; scroll down arrow
CH_FOLDER         = $A0           ; folder icon
CH_PLUS           = $A1           ; [+] box
CH_MINUS          = $A2           ; [-] box
GLYPH_COUNT       = $A3 - GLYPH_BASE ; number of custom characters

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

;------------------------------------------------------------------
.segment "CODE"

;==================================================================
; Program start
;==================================================================
start:
   jsr init_screen                ; 80x60 text, charset, clear screen
   jsr draw_header                ; logo and title
   jsr draw_frame                 ; window borders

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

   ; React when the left button goes down: it was up last frame and
   ; is down now. (Holding the button down doesn't repeat.)
   lda prev_buttons
   and #1
   bne @no_click                  ; was already down
   lda buttons
   and #1
   beq @no_click                  ; is still up
   jsr handle_click
@no_click:
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
; Works out which column was clicked and passes the list position
; on to tree_click or file_click, or scrolls if an arrow was hit.
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
   sta tmp                        ; row within the list, 0..47

   ; which column?
   lda click_col
   cmp #DIV1_X
   bcc @tree                      ; left of the first divider
   beq @tree_arrows               ; on the first divider
   cmp #DIV2_X
   bcc @files                     ; between the dividers
   beq @file_arrows               ; on the second divider
@done:                            ; preview panel: nothing to do yet
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

@tree_arrows:
   ; the scroll arrows are on the top and bottom rows of the divider
   lda tmp
   beq @tree_up
   cmp #LIST_ROWS-1
   bne @done
   lda #PAGE_STEP                 ; bottom arrow: scroll down a page
   jmp scroll_tree
@tree_up:
   lda #256-PAGE_STEP             ; top arrow: scroll up (negative)
   jmp scroll_tree

@file_arrows:
   lda tmp
   beq @file_up
   cmp #LIST_ROWS-1
   bne @done
   lda #PAGE_STEP
   jmp scroll_files
@file_up:
   lda #256-PAGE_STEP
   jmp scroll_files

;------------------------------------------------------------------
; handle_wheel - scroll the column under the mouse pointer.
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
   cpx #DIV1_X+1
   bcc scroll_tree                ; pointer is over the tree
   cpx #DIV2_X+1
   bcc scroll_files               ; pointer is over the files
   rts

;------------------------------------------------------------------
; scroll_tree / scroll_files
; In: A = number of lines to scroll (negative = up). Redraws the
; column if the scroll position actually changed.
;------------------------------------------------------------------
scroll_tree:
   ldx tree_count
   ldy tree_scroll
   jsr calc_scroll
   cmp tree_scroll
   beq :+
   sta tree_scroll
   jsr draw_tree
:  rts

scroll_files:
   ldx file_count
   ldy file_scroll
   jsr calc_scroll
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
;      that still fills the column (count - LIST_ROWS).
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
; mouse pointer off, RAM bank 0, default I/O channels, and SCINIT
; (the KERNAL's CINT) resets the screen mode, colours and character
; set, and clears the screen.
;------------------------------------------------------------------
restore_system:
   lda #0
   ldx #0
   ldy #0
   jsr MOUSE_CONFIG               ; A = 0: hide the mouse pointer
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
