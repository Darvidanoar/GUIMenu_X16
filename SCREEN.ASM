;******************************************************************
; SCREEN.ASM - everything that draws on the screen
;
; HOW THE TEXT SCREEN WORKS
; The VERA video chip has its own 128 KB of video RAM (VRAM) which
; the CPU can't see directly. Instead you write a VRAM address into
; VERA_addr_low/high/bank, then read or write VERA_data0. VERA can
; step the address forward automatically after each access (the
; "increment" in the top 4 bits of VERA_addr_bank), so writing a row
; of characters is just a string of writes to VERA_data0.
;
; In text mode the screen is a "map" at VRAM $1B000. Each character
; cell takes 2 bytes: the screen code (which character to show),
; then the colour byte (background << 4 | foreground). The map is
; 128 cells wide (only 80 are visible), so each row is 256 bytes:
;
;     address of cell (col,row) = $1B000 + row*256 + col*2
;
; which means the high address byte is simply $B0 + row and the low
; byte is col*2. That makes set_cursor very short.
;
; The shapes of the characters (8 bytes each, one per pixel row,
; leftmost pixel in bit 7) are stored at VRAM $1F000, and the 256
; colours of the palette (2 bytes each) at VRAM $1FA00. Text uses
; only the first 16 colours.
;
; THE LOGO
; The Commander X16 logo at the top is a picture, too detailed for
; character cells, so it is drawn with sprites instead: small
; images that VERA draws on top of the text wherever we place them
; (see show_logo).
;
; HOW THE WINDOW IS DRAWN
; Every cell can only have two colours (its foreground and its
; background), so the window's borders are made of custom characters
; that draw thin black lines (foreground) on light grey (background).
; Lines are placed at the very edge of a cell so they join up with
; the neighbouring cells - e.g. the left edge of a list box is a
; grey cell with a black line down its right-hand pixel column,
; sitting next to the white inside of the box.
;
; SCREEN CODES vs PETSCII vs ASCII
; Screen codes are not the same as the PETSCII codes used by CHROUT
; or the ASCII codes CMDR-DOS uses for file names, so text is
; converted on the way out (pet_to_screen, ascii_to_screen).
;
; FIELDS
; Every drawing routine writes into a "field" of a fixed width: the
; variable "remain" holds how many characters are still allowed.
; put_char does nothing once remain reaches 0, so a long name is
; cut off instead of running into the next column, and pad_field
; fills what is left of the field with spaces.
;******************************************************************

; where the hint text on the status line starts, and how much room
; that leaves for the path before it
HINT_X            = PREV_R + 1 - (str_hint_end - str_hint)
STATUS_W          = HINT_X - STATUS_X - 1

; column for the window title, centred in the title bar (which runs
; from WIN_L+2 to WIN_R-3)
TITLE_TEXT_X      = WIN_L + 2 + (WIN_R - WIN_L - 4 - (str_wtitle_end - str_wtitle)) / 2

;------------------------------------------------------------------
; init_screen - 80x60 text mode, upper/lower case character set,
; our palette and custom characters, and an empty dark blue desktop.
;------------------------------------------------------------------
init_screen:
   lda #0                         ; screen mode 0 = 80x60 text
   clc                            ; carry clear = set the mode
   jsr SCREEN_MODE
   lda #3                         ; character set 3 = PETSCII
   jsr SCREEN_SET_CHARSET         ;   upper/lower case
   jsr set_palette

   ; Copy our custom character shapes into the character set,
   ; starting at character GLYPH_BASE ($1F000 + $80*8 = $1F400).
   ; VERA_SET_ADDR (from x16.inc) sets the address with increment 1.
   ; There are fewer than 256 bytes, so X can count through them.
   .assert GLYPH_COUNT*8 <= 256, error, "glyph copy expects <= 256 bytes"
   .assert glyphs_end - glyphs = GLYPH_COUNT*8, error, "wrong number of glyphs"
   VERA_SET_ADDR (VRAM_petscii + GLYPH_BASE*8), 1
   ldx #0
:  lda glyphs,x
   sta VERA_data0
   inx
   cpx #GLYPH_COUNT*8
   bne :-

   ; Fill the whole screen with the desktop colour.
   lda #COL_DESKTOP
   sta cur_color
   lda #SCREEN_COLS
   sta fill_n
   ldy #0                         ; row
@row:
   ldx #0
   lda #$20                       ; space
   jsr hfill
   iny
   cpy #SCREEN_ROWS
   bne @row
   rts

;------------------------------------------------------------------
; set_palette - save the original palette, change some of the text
; colours to our Windows 3.1 colours (see pal_new), and put the
; logo's colours in entries 128-255.
;------------------------------------------------------------------
set_palette:
   VERA_SET_ADDR VRAM_palette, 1  ; save all 512 bytes, in two
   ldx #0                         ;   loops of 256 (each ends when X
:  lda VERA_data0                 ;   wraps round to 0)
   sta pal_save,x
   inx
   bne :-
:  lda VERA_data0
   sta pal_save+256,x
   inx
   bne :-

   ; the logo's colours, made by tools/logo2bin.py: 128 colours of
   ; 2 bytes each = 256 bytes, for entries 128-255
   .assert LOGO_PAL_FIRST = 128, error, "logo palette copy expects 128"
   VERA_SET_ADDR (VRAM_palette + LOGO_PAL_FIRST*2), 1
   ldx #0
:  lda logo_pal,x
   sta VERA_data0
   inx
   bne :-

   ldx #0
@next:
   lda pal_new,x                  ; colour number, $FF = end
   cmp #$FF
   beq @done
   asl                            ; 2 bytes per colour
   sta VERA_addr_low
   lda #>VRAM_palette
   sta VERA_addr_high
   lda #$11                       ; VRAM bank 1, increment 1
   sta VERA_addr_bank
   lda pal_new+1,x                ; green/blue byte
   sta VERA_data0
   lda pal_new+2,x                ; red byte
   sta VERA_data0
   inx
   inx
   inx
   bra @next
@done:
   rts

;------------------------------------------------------------------
; restore_palette - put back the colours saved by set_palette
;------------------------------------------------------------------
restore_palette:
   VERA_SET_ADDR VRAM_palette, 1
   ldx #0
:  lda pal_save,x
   sta VERA_data0
   inx
   bne :-
:  lda pal_save+256,x
   sta VERA_data0
   inx
   bne :-
   rts

; New colours: colour number, then $GB (green, blue), then $0R (red).
; Each of R, G, B goes from 0 (none) to F (full).
pal_new:
   .byte $09, $08, $00            ; 9 navy       #008
   .byte $0A, $06, $00            ; A dark blue  #006
   .byte $0B, $66, $06            ; B grey       #666
   .byte $0C, $00, $00            ; C black      #000
   .byte $0F, $CC, $0C            ; F light grey #CCC
   .byte $FF

;------------------------------------------------------------------
; set_cursor - point VERA at a screen cell, ready to write
; In: X = column, Y = row.  Preserves X and Y.
;------------------------------------------------------------------
set_cursor:
   lda #$11                       ; VRAM bank 1 ($1xxxx), increment 1
   sta VERA_addr_bank
   tya
   clc
   adc #>VRAM_layer1_map          ; high byte = $B0 + row
   sta VERA_addr_high
   txa
   asl                            ; low byte = column * 2
   sta VERA_addr_low
   rts

;------------------------------------------------------------------
; put_char  - write screen code A in colour cur_color at the VERA
;             address, if the field still has room (remain > 0).
;             Preserves X and Y.
; put_pet   - the same, but A is a PETSCII code
;------------------------------------------------------------------
put_pet:
   jsr pet_to_screen
put_char:
   pha                            ; keep the character
   lda remain
   beq @full                      ; field is full: draw nothing
   pla
   sta VERA_data0                 ; character...
   lda cur_color
   sta VERA_data0                 ; ...then its colour
   dec remain
   rts
@full:
   pla
   rts

;------------------------------------------------------------------
; pad_field - fill the rest of the field with spaces
;------------------------------------------------------------------
pad_field:
   lda remain
   beq :+
   lda #$20                       ; space
   jsr put_char
   bra pad_field
:  rts

;------------------------------------------------------------------
; put_ascii - write ASCII character A
;------------------------------------------------------------------
put_ascii:
   jsr ascii_to_screen
   jmp put_char

;------------------------------------------------------------------
; put_ascii_string - write the 0-terminated ASCII string at sptr
;------------------------------------------------------------------
put_ascii_string:
   ldy #0
:  lda (sptr),y
   beq :+                         ; 0 = end of string
   phy
   jsr put_ascii
   ply
   iny
   bne :-
:  rts

;------------------------------------------------------------------
; put_string - write the 0-terminated PETSCII string at sptr
; (our own messages, which the assembler stores as PETSCII)
;------------------------------------------------------------------
put_string:
   ldy #0
:  lda (sptr),y
   beq :+
   phy
   jsr put_pet
   ply
   iny
   bne :-
:  rts

;------------------------------------------------------------------
; put_recname - write the name in recbuf (a copied record). Names
; come from CMDR-DOS, so they are ASCII.
;------------------------------------------------------------------
put_recname:
   ldy #REC_NAME
:  lda recbuf,y
   beq :+
   phy
   jsr put_ascii
   ply
   iny
   cpy #64                        ; never run off the end of recbuf
   bne :-
:  rts

;------------------------------------------------------------------
; print_at - write a PETSCII string anywhere
; In: X = column, Y = row, A = colour, sptr = string
;------------------------------------------------------------------
print_at:
   sta cur_color
   jsr set_cursor
   lda #SCREEN_COLS
   sta remain
   jmp put_string

;------------------------------------------------------------------
; char_at - write one character anywhere
; In: X = column, Y = row, A = screen code, colour in cur_color.
; Preserves X and Y.
;------------------------------------------------------------------
char_at:
   pha
   jsr set_cursor
   lda #1                         ; a field one character wide
   sta remain
   pla
   jmp put_char

;------------------------------------------------------------------
; hfill - write a row of the same character
; In: X = column, Y = row, A = screen code, fill_n = how many,
;     colour in cur_color.  Preserves X, Y and fill_n.
;------------------------------------------------------------------
hfill:
   sta fill_ch
   jsr set_cursor
   lda fill_n
   sta remain
:  lda fill_ch
   jsr put_char
   lda remain
   bne :-
   rts

;------------------------------------------------------------------
; vfill - write a column of the same character
; In: X = column, Y = top row, A = screen code, fill_n = how many,
;     colour in cur_color.  Preserves X and fill_n.
;------------------------------------------------------------------
vfill:
   sta fill_ch
   lda fill_n
   sta fill_left
:  lda fill_ch
   jsr char_at
   iny
   dec fill_left
   bne :-
   rts

;------------------------------------------------------------------
; ascii_to_screen - convert an ASCII character in A to a screen code
; for the upper/lower case character set.
;
;   ASCII         screen code
;   $20-$3F  ->   same          (space, digits, punctuation)
;   $40 @    ->   $00
;   $41-$5A  ->   same          (A-Z)
;   $5B-$5F  ->   $1B-$1F       ([ \ ] ^ _ , shown as their PETSCII
;                                look-alikes)
;   $61-$7A  ->   $01-$1A       (a-z)
;   anything else -> '?'
;------------------------------------------------------------------
ascii_to_screen:
   cmp #$20
   bcc @other
   cmp #$40
   bcc @done                      ; space, digits, punctuation
   beq @at
   cmp #$5B
   bcc @done                      ; A-Z: $41-$5A
   cmp #$60
   bcc @sub40                     ; [ \ ] ^ _
   beq @other
   cmp #$7B
   bcs @other
   sec                            ; a-z: $01-$1A
   sbc #$60
   rts
@sub40:
   sec
   sbc #$40
   rts
@at:
   lda #0
   rts
@other:
   lda #$3F                       ; '?'
@done:
   rts

;------------------------------------------------------------------
; pet_to_screen - convert a PETSCII character in A to a screen code
;
;   PETSCII       screen code
;   $20-$3F  ->   same
;   $40-$5F  ->   $00-$1F
;   $60-$7F  ->   $40-$5F
;   $A0-$BF  ->   $60-$7F
;   $C0-$FE  ->   $40-$7E
;   $FF      ->   $5E
;   control codes ($00-$1F, $80-$9F) -> '?'
;------------------------------------------------------------------
pet_to_screen:
   cmp #$20
   bcc @ctrl
   cmp #$40
   bcc @done                      ; $20-$3F unchanged
   cmp #$60
   bcc @sub40                     ; $40-$5F -> $00-$1F
   cmp #$80
   bcc @sub20                     ; $60-$7F -> $40-$5F
   cmp #$A0
   bcc @ctrl                      ; $80-$9F control codes
   cmp #$C0
   bcc @sub40                     ; $A0-$BF -> $60-$7F
   cmp #$FF
   beq @pi
   and #$7F                       ; $C0-$FE -> $40-$7E
   rts
@sub40:
   and #$3F                       ; $40-$5F become $00-$1F, but
   cmp #$20                       ;   $A0-$BF become $20-$3F, which
   bcc @done                      ;   need moving up to $60-$7F
   ora #$40
   rts
@sub20:
   sec
   sbc #$20
   rts
@pi:
   lda #$5E
   rts
@ctrl:
   lda #$3F                       ; show '?'
@done:
   rts

;------------------------------------------------------------------
; show_logo - show the Commander X16 logo picture at the top left.
;
; A sprite is a small picture (here 64x64 pixels) that VERA draws
; over the text layer at any pixel position. The logo is 320 pixels
; wide, so it is cut into 5 sprites placed side by side:
;
;     +--------+--------+--------+--------+--------+
;     | sprite | sprite | sprite | sprite | sprite |   each 64x64,
;     |   1    |   2    |   3    |   4    |   5    |   only the top
;     +--------+--------+--------+--------+--------+   55 rows used
;
; Sprite 0 is the mouse pointer, so the logo uses sprites 1-5.
; Each pixel is one byte: a palette entry (128-255, set up by
; set_palette), or 0 for "see-through", which lets the dark blue
; desktop show through around the letters.
;
; Step 1 unpacks the pixels into VRAM at LOGO_VRAM. They are stored
; in the program "run-length encoded", because most of the picture
; is see-through: a run of see-through pixels is stored as just
; two bytes, $00 then how many. $00 $00 marks the end. Any other
; byte is one pixel.
;
; Step 2 writes the 5 sprites' attributes (see logo_attr), which
; tell VERA where each sprite's pixels are and where to show it.
;------------------------------------------------------------------
show_logo:
   ; ---- step 1: unpack the pixels ----
   VERA_SET_ADDR LOGO_VRAM, 1
   lda #<logo_rle
   sta sptr
   lda #>logo_rle
   sta sptr+1
@next:
   jsr @get                       ; A = next byte
   bne @pixel                     ; not 0: a single pixel
   jsr @get                       ; 0: A = length of the run
   beq @unpacked                  ; 0 0: the end
   tax
   lda #0
:  sta VERA_data0                 ; X see-through pixels
   dex
   bne :-
   bra @next
@pixel:
   sta VERA_data0
   bra @next

@get:                             ; A = the byte at sptr, and step
   lda (sptr)                     ;   sptr on to the next one
   inc sptr
   bne :+
   inc sptr+1
:  cmp #0                         ; the INCs changed the zero flag:
   rts                            ;   set it again from A

@unpacked:
   ; ---- step 2: the sprite attributes ----
   ; Sprite n's 8 attribute bytes are at VRAM_sprattr + n*8, so
   ; sprites 1-5 are one block of 40 bytes starting at +8.
   VERA_SET_ADDR (VRAM_sprattr + 8), 1
   ldx #0
:  lda logo_attr,x
   sta VERA_data0
   inx
   cpx #LOGO_SPRITES*8
   bne :-

   lda VERA_dc_video              ; make sure sprites are switched on
   ora #$40                       ;   (bit 6). The mouse pointer turns
   sta VERA_dc_video              ;   them on too.
   rts

;------------------------------------------------------------------
; hide_logo - switch the logo sprites off again, by setting their
; "Z-depth" (attribute byte 6) to 0, which means "not shown".
;------------------------------------------------------------------
hide_logo:
   ldx #1                         ; sprites 1-5
@sprite:
   txa                            ; address = VRAM_sprattr + n*8 + 6
   asl
   asl
   asl
   clc
   adc #<(VRAM_sprattr + 6)
   sta VERA_addr_low
   lda #>VRAM_sprattr
   sta VERA_addr_high
   lda #^VRAM_sprattr             ; bank 1, no increment
   sta VERA_addr_bank
   stz VERA_data0
   inx
   cpx #LOGO_SPRITES+1
   bne @sprite
   rts

;------------------------------------------------------------------
; draw_window - the window: border, title bar, grey client area,
; labels, the three list boxes and the status line hint. Drawn once
; at start-up; the lists are drawn inside the boxes later.
;------------------------------------------------------------------
draw_window:
   lda #COL_FRAME
   sta cur_color

   ; ---- the sizing border ----
   lda #WIN_R-WIN_L-1             ; top and bottom edges
   sta fill_n
   ldx #WIN_L+1
   ldy #WIN_T
   lda #CH_W_H
   jsr hfill
   ldy #WIN_B
   lda #CH_W_H
   jsr hfill

   lda #WIN_B-WIN_T-1             ; left and right edges
   sta fill_n
   ldx #WIN_L
   ldy #WIN_T+1
   lda #CH_W_V
   jsr vfill
   ldx #WIN_R
   ldy #WIN_T+1
   lda #CH_W_V
   jsr vfill

   ldx #WIN_L                     ; corners
   ldy #WIN_T
   lda #CH_W_TL
   jsr char_at
   ldx #WIN_R
   lda #CH_W_TR
   jsr char_at
   ldy #WIN_B
   lda #CH_W_BR
   jsr char_at
   ldx #WIN_L
   lda #CH_W_BL
   jsr char_at

   ; the little notches that mark off the corners of the border
   ldx #WIN_L+2
   ldy #WIN_T
   lda #CH_W_NL
   jsr char_at
   ldy #WIN_B
   lda #CH_W_NL
   jsr char_at
   ldx #WIN_R-2
   lda #CH_W_NR
   jsr char_at
   ldy #WIN_T
   lda #CH_W_NR
   jsr char_at
   ldx #WIN_L
   ldy #WIN_T+2
   lda #CH_W_NT
   jsr char_at
   ldx #WIN_R
   lda #CH_W_NT
   jsr char_at
   ldy #WIN_B-2
   lda #CH_W_NB
   jsr char_at
   ldx #WIN_L
   lda #CH_W_NB
   jsr char_at

   ; ---- the title bar ----
   lda #COL_TITLE
   sta cur_color
   lda #WIN_R-WIN_L-4             ; navy bar between the gadgets
   sta fill_n
   ldx #WIN_L+2
   ldy #TITLE_ROW
   lda #$20
   jsr hfill
   lda #<str_wtitle
   sta sptr
   lda #>str_wtitle
   sta sptr+1
   ldx #TITLE_TEXT_X
   ldy #TITLE_ROW
   lda #COL_TITLE
   jsr print_at

   lda #COL_FRAME                 ; the (decorative) gadgets
   sta cur_color
   ldx #WIN_L+1
   ldy #TITLE_ROW
   lda #CH_SYSBOX
   jsr char_at
   ldx #WIN_R-2
   lda #CH_MIN
   jsr char_at
   ldx #WIN_R-1
   lda #CH_MAX
   jsr char_at

   ; ---- the grey client area ----
   lda #WIN_R-WIN_L-1
   sta fill_n
   ldx #WIN_L+1                   ; first row: black line along the
   ldy #CLIENT_TOP                ;   top, under the title bar
   lda #CH_TOPLINE
   jsr hfill
@client:
   iny                            ; the other rows: plain grey
   cpy #WIN_B
   beq :+
   lda #$20
   jsr hfill
   bra @client
:
   ; ---- labels above the boxes ----
   lda #<str_folders
   sta sptr
   lda #>str_folders
   sta sptr+1
   ldx #TREE_X
   ldy #LABEL_ROW
   lda #COL_LABEL
   jsr print_at

   lda #<str_files
   sta sptr
   lda #>str_files
   sta sptr+1
   ldx #FILE_X
   ldy #LABEL_ROW
   lda #COL_LABEL
   jsr print_at

   lda #<str_preview
   sta sptr
   lda #>str_preview
   sta sptr+1
   ldx #PREV_X
   ldy #LABEL_ROW
   lda #COL_LABEL
   jsr print_at

   ; ---- the three boxes ----
   ldx #TREE_L
   ldy #TREE_R
   jsr draw_listbox
   ldx #FILE_L
   ldy #FILE_R
   jsr draw_listbox
   ldx #PREV_L
   ldy #PREV_R
   jsr draw_listbox

   ; the preview box is just white inside, for now
   lda #COL_LIST
   sta cur_color
   lda #PREV_W
   sta fill_n
   ldx #PREV_X
   ldy #LIST_TOP
@preview:
   lda #$20
   jsr hfill
   iny
   cpy #LIST_TOP+LIST_ROWS
   bne @preview

   ; ---- hint on the right of the status line ----
   lda #<str_hint
   sta sptr
   lda #>str_hint
   sta sptr+1
   ldx #HINT_X
   ldy #STATUS_ROW
   lda #COL_STATUS
   jmp print_at

;------------------------------------------------------------------
; draw_listbox - the thin black border around a list box. The box
; runs from row BOX_T to BOX_B; the list rows are inside it.
; In: X = left edge column, Y = right edge column
;------------------------------------------------------------------
draw_listbox:
   stx lb_l
   sty lb_r
   lda #COL_FRAME
   sta cur_color

   tya                            ; width between the corners
   sec
   sbc lb_l
   dec a
   sta fill_n
   inx
   ldy #BOX_T
   lda #CH_LB_T                   ; top edge
   jsr hfill
   ldy #BOX_B
   lda #CH_LB_B                   ; bottom edge
   jsr hfill

   lda #LIST_ROWS
   sta fill_n
   ldx lb_l
   ldy #LIST_TOP
   lda #CH_LB_L                   ; left edge
   jsr vfill
   ldx lb_r
   ldy #LIST_TOP
   lda #CH_LB_R                   ; right edge
   jsr vfill

   ldx lb_l                       ; corners
   ldy #BOX_T
   lda #CH_LB_TL
   jsr char_at
   ldy #BOX_B
   lda #CH_LB_BL
   jsr char_at
   ldx lb_r
   lda #CH_LB_BR
   jsr char_at
   ldy #BOX_T
   lda #CH_LB_TR
   jmp char_at

;------------------------------------------------------------------
; draw_scrollbar - draw a scroll bar
; In: X = column, sb_count = items in the list, sb_scroll = scroll
;     position. The thumb is only drawn if the list can scroll.
;------------------------------------------------------------------
draw_scrollbar:
   stx sb_col
   lda #COL_FRAME
   sta cur_color
   ldy #LIST_TOP
   lda #CH_SB_UP                  ; up arrow
   jsr char_at
   ldy #LIST_TOP+LIST_ROWS-1
   lda #CH_SB_DOWN                ; down arrow
   jsr char_at
   lda #TRACK_ROWS
   sta fill_n
   ldy #TRACK_TOP
   lda #CH_SB_TRACK               ; empty track
   jsr vfill
   jsr thumb_row                  ; where does the thumb go?
   bcs :+                         ; nowhere: the list doesn't scroll
   tay
   ldx sb_col
   lda #CH_SB_THUMB
   jmp char_at
:  rts

;------------------------------------------------------------------
; draw_tree - redraw the folder list and its scroll bar
;
; Each of the list rows shows node (tree_scroll + row), like this:
;
;     <indent>[+]<folder icon> NAME
;
; The indent is one space per level of depth (at most 10). The box
; shows [+] if the folder hasn't been expanded, [-] if it has, and
; nothing if it turned out to have no sub-folders. The open folder
; is highlighted.
;------------------------------------------------------------------
draw_tree:
   stz tmp                        ; tmp = list row
@row:
   ; start a TREE_W wide field at the start of this row
   lda tmp
   clc
   adc #LIST_TOP
   tay
   ldx #TREE_X
   jsr set_cursor
   lda #TREE_W
   sta remain
   lda #COL_LIST
   sta cur_color

   ; node number = row + scroll position; blank if past the end
   lda tmp
   clc
   adc tree_scroll
   bcs @empty
   cmp tree_count
   bcs @empty
   sta tmp+1                      ; tmp+1 = node number
   jsr tree_ptr                   ; ptr -> node in banked RAM
   jsr load_rec                   ; copy it into recbuf

   ; colour: highlighted if it is the open folder
   lda #COL_LIST
   ldx tmp+1
   cpx tree_sel
   bne :+
   lda #COL_SEL
:  sta cur_color

   ; indent by depth (max 10)
   lda recbuf+REC_DEPTH
   cmp #11
   bcc :+
   lda #10
:  sta tmp+2                      ; tmp+2 = spaces still to write
@indent:
   lda tmp+2
   beq @box
   lda #$20
   jsr put_char
   dec tmp+2
   bra @indent

@box:
   ; choose [+], [-] or a space. BIT #imm tests bits of A
   ; without changing it.
   lda recbuf+REC_FLAGS
   ldx #CH_PLUS
   bit #FLAG_EXPANDED
   beq :+                         ; not expanded: [+]
   ldx #CH_MINUS
   bit #FLAG_NOKIDS
   beq :+                         ; expanded: [-]
   ldx #$20                       ; expanded but empty: space
:  txa
   jsr put_char

   ; the folder icon, in orange on the row's background
   lda cur_color
   pha
   and #$F0
   ora #COL_FOLDER
   sta cur_color
   lda #CH_FOLDER
   jsr put_char
   pla
   sta cur_color

   lda #$20
   jsr put_char
   jsr put_recname
@empty:
   jsr pad_field                  ; blank out the rest of the row
   inc tmp
   lda tmp
   cmp #LIST_ROWS
   beq :+
   jmp @row                       ; (too far for a branch)
:
   lda tree_count                 ; and the scroll bar
   sta sb_count
   lda tree_scroll
   sta sb_scroll
   ldx #TREE_SB
   jmp draw_scrollbar

;------------------------------------------------------------------
; draw_files - redraw the file list and its scroll bar
;
; Each row shows file (file_scroll + row) of the sorted list
; (programs first, then other files, each group in name order).
; Programs are blue, other files black, and the highlighted file
; gets a navy bar. An empty folder shows "(no files)", and a folder
; that couldn't be read shows an error.
;------------------------------------------------------------------
draw_files:
   stz tmp                        ; tmp = list row
@row:
   ; start a FILE_W wide field at the start of this row
   lda tmp
   clc
   adc #LIST_TOP
   tay
   ldx #FILE_X
   jsr set_cursor
   lda #FILE_W
   sta remain
   lda #COL_LIST
   sta cur_color

   ; position in the sorted list = row + scroll position
   lda tmp
   clc
   adc file_scroll
   bcs @empty
   cmp file_count
   bcs @maybe_none                ; past the last file
   sta tmp+1                      ; tmp+1 = position in sorted list
   tax
   lda file_order,x               ; record number of that file
   jsr file_ptr
   jsr load_rec                   ; copy it into recbuf

   ; pick colours: X = normal colour, Y = highlighted colour
   ldx #COL_FILE                  ; an ordinary file: grey
   ldy #COL_SEL
   lda recbuf+REC_FLAGS
   and #FLAG_PRG
   beq :+
   ldx #COL_PRG                   ; a program
   ldy #COL_SEL_PRG
:  lda tmp+1
   cmp file_sel
   beq :+
   txa                            ; not highlighted
   bra :++
:  tya                            ; highlighted
:  sta cur_color

   lda #$20                       ; one space margin, then the name
   jsr put_char
   jsr put_recname
   bra @empty

@maybe_none:
   ; On the first row of an empty folder, say why it is empty.
   lda tmp
   ora file_count                 ; both 0?
   bne @empty
   lda #COL_EMPTY
   sta cur_color
   lda dir_error
   beq :+
   lda #COL_ERROR                 ; couldn't read the folder
   sta cur_color
   lda #<str_dir_error
   ldx #>str_dir_error
   bra :++
:  lda #<str_no_files             ; folder has no files
   ldx #>str_no_files
:  sta sptr
   stx sptr+1
   jsr put_string
@empty:
   jsr pad_field                  ; blank out the rest of the row
   inc tmp
   lda tmp
   cmp #LIST_ROWS
   beq :+
   jmp @row                       ; (too far for a branch)
:
   lda file_count                 ; and the scroll bar
   sta sb_count
   lda file_scroll
   sta sb_scroll
   ldx #FILE_SB
   jmp draw_scrollbar

;------------------------------------------------------------------
; draw_status - show the open folder's path (e.g. /GAMES/ARCADE)
; on the status line, in the space to the left of the hint.
;------------------------------------------------------------------
draw_status:
   ldx #STATUS_X
   ldy #STATUS_ROW
   jsr set_cursor
   lda #COL_STATUS
   sta cur_color
   lda #STATUS_W
   sta remain
   lda #<pathbuf
   sta sptr
   lda #>pathbuf
   sta sptr+1
   jsr put_ascii_string
   jmp pad_field

.pushseg
.segment "BSS"
fill_ch:   .res 1                 ; character for hfill / vfill
fill_left: .res 1                 ; rows left for vfill
lb_l:      .res 1                 ; list box edges for draw_listbox
lb_r:      .res 1
sb_col:    .res 1                 ; column for draw_scrollbar
.popseg

;------------------------------------------------------------------
; Text. With "-t cx16" the assembler stores strings as PETSCII.
;------------------------------------------------------------------
str_wtitle:    .byte "SD Card Program Launcher"
str_wtitle_end: .byte 0
str_folders:   .byte "Folders:", 0
str_files:     .byte "Files:", 0
str_preview:   .byte "Preview:", 0
str_no_files:  .byte " (no files)", 0
str_dir_error: .byte " Unable to read folder", 0
str_hint:      .byte "Double-click a program to run it.  Q = Quit"
str_hint_end:  .byte 0

;------------------------------------------------------------------
; The logo picture, made from CommanderX16_320.png by
; tools/logo2bin.py (see that script for the file formats).
;------------------------------------------------------------------
logo_pal:   .incbin "LOGO.PAL"    ; colours for palette entries 128-255
logo_rle:   .incbin "LOGO.RLE"    ; the pixels, run-length encoded

; Sprite attributes for sprites 1-5, 8 bytes each:
;   bytes 0-1  where the pixels are in VRAM, divided by 32 (bits
;              12-5 of the address, then bits 16-13), and bit 7 of
;              byte 1 set = 8 bits per pixel
;   bytes 2-3  X position in pixels
;   bytes 4-5  Y position in pixels
;   byte 6     Z-depth in bits 3-2: 3 = in front of the text
;   byte 7     size: height in bits 7-6, width in bits 5-4
;              (3 = 64 pixels for both = $F0); palette offset 0
logo_attr:
.repeat LOGO_SPRITES, I
   .byte <((LOGO_VRAM + I*LOGO_SPR_BYTES) >> 5)
   .byte $80 | ((LOGO_VRAM + I*LOGO_SPR_BYTES) >> 13)
   .word LOGO_X + I*64
   .word LOGO_Y
   .byte $0C
   .byte $F0
.endrep

;------------------------------------------------------------------
; Custom character shapes, copied over screen codes $80-$9C by
; init_screen. Each character is 8 bytes, top row first; in each
; byte bit 7 is the leftmost pixel and a 1 bit is drawn in the
; foreground colour. For example the window's top-left corner
; ($80) is:
;
;     $FF  ########     black outer edge along the top...
;     $80  #.......     ...and down the left
;     $80  #.......
;     $80  #.......
;     $80  #.......
;     $80  #.......
;     $80  #.......
;     $81  #......#     the inner edge starts at the far corner
;------------------------------------------------------------------
glyphs:
   ; ---- $80-$89: window sizing border ----
   ; grey, with a black line on the outside and inside edges
   .byte $FF,$80,$80,$80,$80,$80,$80,$81   ; $80 top left corner
   .byte $FF,$01,$01,$01,$01,$01,$01,$81   ; $81 top right corner
   .byte $81,$80,$80,$80,$80,$80,$80,$FF   ; $82 bottom left corner
   .byte $81,$01,$01,$01,$01,$01,$01,$FF   ; $83 bottom right corner
   .byte $FF,$00,$00,$00,$00,$00,$00,$FF   ; $84 top/bottom edge
   .byte $81,$81,$81,$81,$81,$81,$81,$81   ; $85 left/right edge
   .byte $FF,$80,$80,$80,$80,$80,$80,$FF   ; $86 notch, left side
   .byte $FF,$01,$01,$01,$01,$01,$01,$FF   ; $87 notch, right side
   .byte $FF,$81,$81,$81,$81,$81,$81,$81   ; $88 notch, top side
   .byte $81,$81,$81,$81,$81,$81,$81,$FF   ; $89 notch, bottom side
   ; ---- $8A-$8D: title bar ----
   .byte $01,$01,$01,$7F,$43,$7F,$01,$01   ; $8A control-menu box
   .byte $80,$80,$80,$BE,$9C,$88,$80,$80   ; $8B minimise (down)
   .byte $80,$80,$88,$9C,$BE,$80,$80,$80   ; $8C maximise (up)
   .byte $FF,$00,$00,$00,$00,$00,$00,$00   ; $8D line under title
   ; ---- $8E-$95: list box border (thin black line) ----
   .byte $00,$00,$00,$00,$00,$00,$00,$01   ; $8E top left
   .byte $00,$00,$00,$00,$00,$00,$00,$FF   ; $8F top
   .byte $00,$00,$00,$00,$00,$00,$00,$80   ; $90 top right
   .byte $01,$01,$01,$01,$01,$01,$01,$01   ; $91 left
   .byte $80,$80,$80,$80,$80,$80,$80,$80   ; $92 right
   .byte $01,$00,$00,$00,$00,$00,$00,$00   ; $93 bottom left
   .byte $FF,$00,$00,$00,$00,$00,$00,$00   ; $94 bottom
   .byte $80,$00,$00,$00,$00,$00,$00,$00   ; $95 bottom right
   ; ---- $96-$99: scroll bar ----
   .byte $80,$80,$88,$9C,$BE,$80,$80,$FF   ; $96 up arrow button
   .byte $FF,$80,$80,$BE,$9C,$88,$80,$80   ; $97 down arrow button
   .byte $80,$80,$80,$80,$80,$80,$80,$80   ; $98 track
   .byte $FF,$80,$BE,$BE,$BE,$BE,$80,$FF   ; $99 thumb
   ; ---- $9A-$9C: tree ----
   .byte $00,$E0,$FF,$FF,$FF,$FF,$FF,$00   ; $9A folder icon (filled)
   .byte $FE,$82,$92,$BA,$92,$82,$FE,$00   ; $9B [+] box
   .byte $FE,$82,$82,$BA,$82,$82,$FE,$00   ; $9C [-] box
glyphs_end:
