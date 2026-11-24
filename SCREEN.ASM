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
; The window copies the Amiga's Workbench 2.0/3.1: grey, with 3D
; edges made of a white line and a black line. White at the top and
; left with black at the bottom and right looks raised (the window);
; black at the top and left with white at the bottom and right looks
; sunken (the list boxes).
;
; Every cell can only have two colours (its foreground and its
; background), but a corner where a white line meets a black one
; would need three. So each edge is a thin line along one side of a
; cell (custom characters CH_E_L, CH_E_R, CH_E_T, CH_E_B), and each
; line is put in the cell next to the edge where it is the only
; line. For example a list box's sunken edge is drawn in the grey
; cells around the list:
;
;      .  .  .  .  .  .  .
;      .  ########## (black line along the bottom of the cells)
;      .  #  list         #
;      .  #  (black       #   <- white line down the left-hand side
;      .  #   line down   #      of the cells to the right
;      .  #   the right)  #
;      .  ######### (white line along the top of the cells below)
;
; The window's own raised outer edge is drawn the same way, on the
; desktop cells just outside the window.
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

; column for the window title
TITLE_TEXT_X      = WIN_L + 3      ; left-aligned after the close
                                   ;   gadget, as on the Amiga

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
; colours to our Workbench colours (see pal_new), and put the
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
   .byte $06, $2A, $02            ; 6 file blue  #22A
   .byte $09, $8B, $06            ; 9 Amiga blue #68B
   .byte $0A, $06, $00            ; A dark blue  #006
   .byte $0B, $66, $06            ; B dark grey  #666
   .byte $0C, $00, $00            ; C black      #000
   .byte $0F, $AA, $0A            ; F Amiga grey #AAA
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
; draw_window - the window: its raised edges, the blue title bar
; with its gadgets, the grey inside, labels, the three list boxes
; and the status line hint. Drawn once at start-up; the lists are
; drawn inside the boxes later.
;------------------------------------------------------------------
draw_window:
   ; ---- the outer edge, on the desktop just outside the window ----
   ; White along the top and down the left, black along the bottom
   ; and down the right, so the window looks raised.
   lda #COL_OUT_LIGHT
   sta cur_color
   lda #WIN_R-WIN_L+1
   sta fill_n
   ldx #WIN_L
   ldy #WIN_T-1
   lda #CH_E_B                    ; along the top
   jsr hfill
   ldx #WIN_L-1
   lda #CH_C_BR                   ; top left corner: one dot
   jsr char_at
   lda #WIN_B-WIN_T+1
   sta fill_n
   ldy #WIN_T
   lda #CH_E_R                    ; down the left
   jsr vfill

   lda #COL_OUT_DARK
   sta cur_color
   ldx #WIN_R+1
   ldy #WIN_T
   lda #CH_E_L                    ; down the right
   jsr vfill
   ldy #WIN_T-1
   lda #CH_C_BL                   ; top right corner
   jsr char_at
   ldy #WIN_B+1
   lda #CH_C_TL                   ; bottom right corner
   jsr char_at
   ldx #WIN_L-1
   lda #CH_C_TR                   ; bottom left corner
   jsr char_at
   lda #WIN_R-WIN_L+1
   sta fill_n
   ldx #WIN_L
   lda #CH_E_T                    ; along the bottom
   jsr hfill

   ; ---- the title bar ----
   lda #COL_TITLE                 ; blue all the way across
   sta cur_color
   ldy #WIN_T
   lda #$20
   jsr hfill                      ; (X and fill_n are still right)

   ldx #WIN_L                     ; close gadget at the left
   lda #CH_CLOSE
   jsr char_at
   inx
   lda #CH_CLOSE+1
   jsr char_at

   ; zoom and depth gadgets at the right: 4 characters in a row,
   ; CH_ZOOM, CH_ZOOM+1, CH_DEPTH, CH_DEPTH+1
   .assert CH_DEPTH = CH_ZOOM+2, error, "gadget characters must be in order"
   lda #CH_ZOOM
   sta tmp
   ldx #WIN_R-3
:  lda tmp
   jsr char_at
   inc tmp
   inx
   cpx #WIN_R+1
   bne :-

   lda #<str_wtitle               ; the title
   sta sptr
   lda #>str_wtitle
   sta sptr+1
   ldx #TITLE_TEXT_X
   ldy #WIN_T
   lda #COL_TITLE
   jsr print_at

   ; ---- the grey inside, everything below the title bar ----
   lda #COL_DARK
   sta cur_color
   lda #WIN_R-WIN_L+1
   sta fill_n
   ldx #WIN_L
   ldy #WIN_T+1
@client:
   lda #$20
   jsr hfill
   iny
   cpy #WIN_B+1
   bne @client

   ; ---- the inner edge ----
   ; The border is the outermost column/row of cells all round
   ; (below the title bar). Inside it is a sunken edge: black along
   ; the top and down the left, white along the bottom and down the
   ; right. Together with the outer edge this makes the border look
   ; like a raised frame, as on Workbench.
   ldx #WIN_L                     ; (colour is still COL_DARK)
   ldy #WIN_T+1
   lda #CH_C_TR                   ; top left corner: one dot, where
   jsr char_at                    ;   the top and left lines meet
   lda #WIN_R-WIN_L
   sta fill_n
   inx
   lda #CH_E_T                    ; along the top, under the title
   jsr hfill
   lda #WIN_B-WIN_T-1
   sta fill_n
   ldx #WIN_L
   ldy #WIN_T+2
   lda #CH_E_R                    ; down the left
   jsr vfill

   lda #COL_LIGHT
   sta cur_color
   lda #WIN_B-WIN_T-2
   sta fill_n
   ldx #WIN_R
   ldy #WIN_T+2
   lda #CH_E_L                    ; down the right
   jsr vfill                      ; (leaves Y = WIN_B)
   lda #CH_C_TL                   ; bottom right corner: one dot
   jsr char_at
   lda #WIN_R-WIN_L-1
   sta fill_n
   ldx #WIN_L+1
   lda #CH_E_T                    ; along the bottom
   jsr hfill

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

   ; the preview box is just empty inside, for now
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
; draw_listbox - the sunken edge around a list box: black along the
; top and down the left, white along the bottom and down the right.
; The box runs from row BOX_T to BOX_B; the list rows are inside it.
; In: X = left edge column, Y = right edge column
;------------------------------------------------------------------
draw_listbox:
   stx lb_l
   sty lb_r
   tya                            ; width between the corners
   sec
   sbc lb_l
   dec a
   sta lb_w

   ; ---- the black (dark) edges ----
   lda #COL_DARK
   sta cur_color
   lda lb_w
   sta fill_n
   inx
   ldy #BOX_T
   lda #CH_E_B                    ; top edge
   jsr hfill
   ldx lb_l
   lda #CH_C_BR                   ; top left corner
   jsr char_at
   ldx lb_r
   lda #CH_C_BL                   ; top right corner (the end of
   jsr char_at                    ;   the top edge)
   lda #LIST_ROWS
   sta fill_n
   ldx lb_l
   ldy #LIST_TOP
   lda #CH_E_R                    ; left edge
   jsr vfill                      ; (leaves Y = BOX_B)
   lda #CH_C_TR                   ; bottom left corner (the end of
   jsr char_at                    ;   the left edge)

   ; ---- the white (light) edges ----
   lda #COL_LIGHT
   sta cur_color
   ldx lb_r
   lda #CH_C_TL                   ; bottom right corner
   jsr char_at
   lda lb_w
   sta fill_n
   ldx lb_l
   inx
   lda #CH_E_T                    ; bottom edge
   jsr hfill
   lda #LIST_ROWS
   sta fill_n
   ldx lb_r
   ldy #LIST_TOP
   lda #CH_E_L                    ; right edge
   jmp vfill

;------------------------------------------------------------------
; draw_scrollbar - draw a scroll bar, Amiga style: the track from
; the top, with the up and down arrows together at the bottom.
; In: X = column, sb_count = items in the list, sb_scroll = scroll
;     position. The thumb is only drawn if the list can scroll.
;------------------------------------------------------------------
draw_scrollbar:
   stx sb_col
   lda #COL_FRAME
   sta cur_color
   ldy #SB_UP_ROW
   lda #CH_SB_UP                  ; up arrow
   jsr char_at
   ldy #SB_DOWN_ROW
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

   ; colour: highlighted if it is the open folder (blue if the
   ; tree has the keyboard focus, dark grey if not)
   lda #COL_LIST
   ldx tmp+1
   cpx tree_sel
   bne :+
   lda #COL_SEL
   ldx focus
   cpx #FOCUS_TREE
   beq :+
   lda #COL_SEL_DIM
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
; gets a blue bar. An empty folder shows "(no files)", and a folder
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
   ldx #COL_FILE                  ; an ordinary file
   ldy #COL_SEL
   lda recbuf+REC_FLAGS
   and #FLAG_PRG
   beq :+
   ldx #COL_PRG                   ; a program
   ldy #COL_SEL_PRG
:  lda focus                      ; no keyboard focus: the highlight
   cmp #FOCUS_FILES               ;   is dark grey instead of blue
   beq :+
   ldy #COL_SEL_DIM
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
lb_w:      .res 1                 ; list box width between corners
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
str_hint:      .byte "Double-click or RETURN to run.  Q = Quit"
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
; Custom character shapes, copied over screen codes $80-$93 by
; init_screen. Each character is 8 bytes, top row first; in each
; byte bit 7 is the leftmost pixel and a 1 bit is drawn in the
; foreground colour. For example the up arrow button ($8E) is:
;
;     $FF  ########     line along the top (between it and the track)
;     $80  #.......     line down the left (between it and the list)
;     $88  #...#...
;     $9C  #..###..     the arrow
;     $BE  #.#####.
;     $80  #.......
;     $80  #.......
;     $80  #.......
;------------------------------------------------------------------
glyphs:
   ; ---- $80-$87: edges (see "HOW THE WINDOW IS DRAWN") ----
   .byte $01,$01,$01,$01,$01,$01,$01,$01   ; $80 line down the right
   .byte $80,$80,$80,$80,$80,$80,$80,$80   ; $81 line down the left
   .byte $00,$00,$00,$00,$00,$00,$00,$FF   ; $82 line along the bottom
   .byte $FF,$00,$00,$00,$00,$00,$00,$00   ; $83 line along the top
   .byte $00,$00,$00,$00,$00,$00,$00,$01   ; $84 dot bottom right
   .byte $00,$00,$00,$00,$00,$00,$00,$80   ; $85 dot bottom left
   .byte $01,$00,$00,$00,$00,$00,$00,$00   ; $86 dot top right
   .byte $80,$00,$00,$00,$00,$00,$00,$00   ; $87 dot top left
   ; ---- $88-$8D: title bar gadgets, 2 characters (16 pixels) each ----
   ; close: a small box with a dot in it, then a dividing line
   .byte $00,$07,$04,$05,$05,$04,$07,$00   ; $88 close, left half
   .byte $01,$E1,$21,$A1,$A1,$21,$E1,$01   ; $89 close, right half
   ; zoom: a dividing line, then a box with a smaller box in its
   ; top left corner
   .byte $80,$8F,$8F,$8F,$88,$88,$8F,$80   ; $8A zoom, left half
   .byte $00,$FC,$84,$84,$04,$04,$FC,$00   ; $8B zoom, right half
   ; depth: a dividing line, then two overlapping boxes, the front
   ; one filled
   .byte $80,$9F,$90,$93,$9F,$83,$83,$80   ; $8C depth, left half
   .byte $00,$C0,$40,$F8,$F8,$F8,$F8,$00   ; $8D depth, right half
   ; ---- $8E-$90: scroll bar ----
   .byte $FF,$80,$88,$9C,$BE,$80,$80,$80   ; $8E up arrow button
   .byte $FF,$80,$BE,$9C,$88,$80,$80,$80   ; $8F down arrow button
   .byte $BE,$A3,$A3,$A3,$A3,$A3,$BF,$9F   ; $90 thumb (a box with a
                                           ;   shadow on the right
                                           ;   and bottom)
   ; ---- $91-$93: tree ----
   .byte $00,$E0,$FF,$FF,$FF,$FF,$FF,$00   ; $91 folder icon (filled)
   .byte $FE,$82,$92,$BA,$92,$82,$FE,$00   ; $92 [+] box
   .byte $FE,$82,$82,$BA,$82,$82,$FE,$00   ; $93 [-] box
glyphs_end:
