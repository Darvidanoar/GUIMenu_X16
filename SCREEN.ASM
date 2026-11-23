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
; leftmost pixel in bit 7) are stored at VRAM $1F000.
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

;------------------------------------------------------------------
; init_screen - 80x60 text mode, upper/lower case character set,
; our custom characters, and a blank blue screen.
;------------------------------------------------------------------
init_screen:
   lda #0                         ; screen mode 0 = 80x60 text
   clc                            ; carry clear = set the mode
   jsr SCREEN_MODE
   lda #3                         ; character set 3 = PETSCII
   jsr SCREEN_SET_CHARSET         ;   upper/lower case

   ; Copy our custom character shapes into the character set,
   ; starting at character GLYPH_BASE ($1F000 + $80*8 = $1F400).
   ; VERA_SET_ADDR (from x16.inc) sets the address with increment 1.
   ; There are more than 256 bytes, so it is done in two loops.
   VERA_SET_ADDR (VRAM_petscii + GLYPH_BASE*8), 1
   ldx #0
:  lda glyphs,x                   ; first 256 bytes
   sta VERA_data0
   inx
   bne :-                         ; until X wraps round to 0
:  lda glyphs+256,x               ; the rest
   sta VERA_data0
   inx
   cpx #GLYPH_COUNT*8-256
   bne :-

   ; Clear every row of the screen to spaces, white on blue.
   ldy #0                         ; row
@row:
   ldx #0                         ; column
   jsr set_cursor
   lda #COL_SCREEN
   sta cur_color
   lda #SCREEN_COLS               ; field = the whole row
   sta remain
   jsr pad_field                  ; fill it with spaces
   iny
   cpy #SCREEN_ROWS
   bne @row
   rts

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
; hline - draw a horizontal border line
; In: X = column, Y = row, A = length
;------------------------------------------------------------------
hline:
   sta remain
   jsr set_cursor
:  lda #CH_H
   jsr put_char
   lda remain
   bne :-
   rts

;------------------------------------------------------------------
; vline - draw a vertical border line down the list area
; (rows LIST_TOP to LIST_TOP+LIST_ROWS-1)
; In: X = column
;------------------------------------------------------------------
vline:
   ldy #LIST_TOP
:  lda #CH_V
   jsr char_at
   iny
   cpy #LIST_TOP+LIST_ROWS
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
; draw_header - the X16 logo and the title text
;
; The logo is the same one the X16 shows when it starts: 7 rows of
; 7 characters (see "logo" below), each row in its own colour.
;------------------------------------------------------------------
draw_header:
   ldy #0                         ; Y = logo row 0..6
@row:
   lda logo_colors,y              ; this row's colour
   sta cur_color
   ldx #LOGO_X
   phy
   tya
   clc
   adc #LOGO_Y                    ; screen row = LOGO_Y + logo row
   tay
   jsr set_cursor
   ply
   lda #7                         ; 7 characters per row
   sta remain
   ; X = offset of this row in the logo table = row * 7
   ; (worked out as row * 8 - row)
   tya
   sta tmp
   asl
   asl
   asl
   sec
   sbc tmp
   tax
@col:
   lda logo,x
   phx
   jsr put_char
   plx
   inx
   lda remain
   bne @col                       ; until the 7 are done
   iny
   cpy #7
   bne @row

   ; "Commander X16"
   lda #<str_title
   sta sptr
   lda #>str_title
   sta sptr+1
   ldx #TITLE_X
   ldy #LOGO_Y+2
   lda #COL_TITLE
   jsr print_at

   ; "SD Card Program Launcher"
   lda #<str_subtitle
   sta sptr
   lda #>str_subtitle
   sta sptr+1
   ldx #TITLE_X
   ldy #LOGO_Y+4
   lda #COL_SUBTITLE
   jmp print_at

;------------------------------------------------------------------
; draw_frame - the window's borders, column titles and hint text.
; Drawn once at start-up; the lists are drawn inside it later.
;------------------------------------------------------------------
draw_frame:
   lda #COL_BORDER
   sta cur_color

   ; top border:  +-------+-------+-------+
   ldx #LEFT_X
   ldy #WIN_TOP
   lda #SCREEN_COLS
   jsr hline
   ldy #WIN_TOP
   ldx #LEFT_X
   lda #CH_TL
   jsr char_at
   ldx #DIV1_X
   lda #CH_TT
   jsr char_at
   ldx #DIV2_X
   lda #CH_TT
   jsr char_at
   ldx #RIGHT_X
   lda #CH_TR
   jsr char_at

   ; line above the status line:  |-------+-------+-------|
   ldx #LEFT_X
   ldy #SEP_ROW
   lda #SCREEN_COLS
   jsr hline
   ldy #SEP_ROW
   ldx #LEFT_X
   lda #CH_LT
   jsr char_at
   ldx #DIV1_X
   lda #CH_BT
   jsr char_at
   ldx #DIV2_X
   lda #CH_BT
   jsr char_at
   ldx #RIGHT_X
   lda #CH_RT
   jsr char_at

   ; bottom border:  +-----------------------+
   ldx #LEFT_X
   ldy #WIN_BOTTOM
   lda #SCREEN_COLS
   jsr hline
   ldy #WIN_BOTTOM
   ldx #LEFT_X
   lda #CH_BL
   jsr char_at
   ldx #RIGHT_X
   lda #CH_BR
   jsr char_at

   ; the four vertical lines down the list area
   ldx #LEFT_X
   jsr vline
   ldx #DIV1_X
   jsr vline
   ldx #DIV2_X
   jsr vline
   ldx #RIGHT_X
   jsr vline
   ; and the two at either end of the status line
   ldy #STATUS_ROW
   ldx #LEFT_X
   lda #CH_V
   jsr char_at
   ldx #RIGHT_X
   lda #CH_V
   jsr char_at

   ; column titles, written over the top border
   lda #<str_folders
   sta sptr
   lda #>str_folders
   sta sptr+1
   ldx #TREE_X+1
   ldy #WIN_TOP
   lda #COL_TITLE
   jsr print_at

   lda #<str_files
   sta sptr
   lda #>str_files
   sta sptr+1
   ldx #FILE_X+1
   ldy #WIN_TOP
   lda #COL_TITLE
   jsr print_at

   lda #<str_preview
   sta sptr
   lda #>str_preview
   sta sptr+1
   ldx #PREV_X+1
   ldy #WIN_TOP
   lda #COL_TITLE
   jsr print_at

   ; hint, right-aligned on the status line
   lda #<str_hint
   sta sptr
   lda #>str_hint
   sta sptr+1
   ldx #RIGHT_X-(str_hint_end-str_hint)
   ldy #STATUS_ROW
   lda #COL_HINT
   jmp print_at

;------------------------------------------------------------------
; draw_tree - redraw the folder column
;
; Each of the 48 rows shows node (tree_scroll + row), like this:
;
;     <indent>[+]<folder icon> NAME
;
; The indent is one space per level of depth (at most 10). The box
; shows [+] if the folder hasn't been expanded, [-] if it has, and
; nothing if it turned out to have no sub-folders. The open folder
; is highlighted.
;------------------------------------------------------------------
draw_tree:
   stz tmp                        ; tmp = list row 0..47
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
   lda #COL_SCREEN
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
   lda #COL_DIR
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
   lda #CH_FOLDER
   jsr put_char
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
:  jmp draw_tree_arrows

;------------------------------------------------------------------
; draw_tree_arrows - show scroll arrows on the divider to the right
; of the tree: an up arrow at the top if the list is scrolled down,
; a down arrow at the bottom if there are more nodes below. Where
; there is no arrow, the plain divider line is drawn.
;------------------------------------------------------------------
draw_tree_arrows:
   lda #COL_BORDER
   sta cur_color
   lda #CH_V
   ldy tree_scroll
   beq :+                         ; at the top: no up arrow
   lda #CH_UP
:  ldx #DIV1_X
   ldy #LIST_TOP
   jsr char_at
   lda tree_scroll                ; last shown + 1 = scroll + 48
   clc
   adc #LIST_ROWS
   bcs @no_down
   cmp tree_count
   bcs @no_down                   ; nothing below: no down arrow
   lda #CH_DOWN
   bra @draw
@no_down:
   lda #CH_V
@draw:
   ldx #DIV1_X
   ldy #LIST_TOP+LIST_ROWS-1
   jmp char_at

;------------------------------------------------------------------
; draw_files - redraw the file column
;
; Each row shows file (file_scroll + row) of the sorted list.
; Programs are yellow, other files light grey, and the highlighted
; file gets a coloured bar. An empty folder shows "(no files)", and
; a folder that couldn't be read shows an error.
;------------------------------------------------------------------
draw_files:
   stz tmp                        ; tmp = list row 0..47
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
   lda #COL_SCREEN
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
   ldx #COL_FILE
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
   lda #COL_HINT
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
   ; scroll arrows on the divider to the right (see draw_tree_arrows)
   lda #COL_BORDER
   sta cur_color
   lda #CH_V
   ldy file_scroll
   beq :+
   lda #CH_UP
:  ldx #DIV2_X
   ldy #LIST_TOP
   jsr char_at
   lda file_scroll
   clc
   adc #LIST_ROWS
   bcs @no_down
   cmp file_count
   bcs @no_down
   lda #CH_DOWN
   bra @draw
@no_down:
   lda #CH_V
@draw:
   ldx #DIV2_X
   ldy #LIST_TOP+LIST_ROWS-1
   jmp char_at

;------------------------------------------------------------------
; draw_status - show the open folder's path (e.g. /GAMES/ARCADE)
; on the status line, in the space to the left of the hint.
;------------------------------------------------------------------
draw_status:
   ldx #LEFT_X+2
   ldy #STATUS_ROW
   jsr set_cursor
   lda #COL_STATUS
   sta cur_color
   lda #RIGHT_X-(str_hint_end-str_hint)-LEFT_X-3
   sta remain                     ; up to where the hint starts
   lda #<pathbuf
   sta sptr
   lda #>pathbuf
   sta sptr+1
   jsr put_ascii_string
   jmp pad_field

;------------------------------------------------------------------
; Text. With "-t cx16" the assembler stores strings as PETSCII.
;------------------------------------------------------------------
str_title:     .byte "Commander X16", 0
str_subtitle:  .byte "SD Card Program Launcher", 0
str_folders:   .byte " Folders ", 0
str_files:     .byte " Files ", 0
str_preview:   .byte " Preview ", 0
str_no_files:  .byte " (no files)", 0
str_dir_error: .byte " Unable to read folder", 0
str_hint:      .byte "Double-click a program to run it  Q=Quit "
str_hint_end:  .byte 0

;------------------------------------------------------------------
; The Commander X16 logo: 7 rows of 7 screen codes. $20 is a space;
; $80-$92 are the custom logo pieces in "glyphs" below. These are
; the same shapes and colours as the logo on the X16's start-up
; screen.
;------------------------------------------------------------------
logo:
   .byte $80,$20,$20,$20,$20,$20,$82
   .byte $81,$80,$20,$20,$20,$82,$83
   .byte $84,$85,$80,$20,$82,$85,$86
   .byte $20,$87,$88,$20,$89,$87,$20
   .byte $20,$8A,$8B,$20,$8C,$8A,$20
   .byte $8D,$85,$8E,$20,$8F,$85,$90
   .byte $91,$8E,$20,$20,$20,$8F,$92

; colour of each logo row (on the blue background):
; purple, light blue, cyan, green, yellow, orange, red
logo_colors:
   .byte $64,$6E,$63,$65,$67,$68,$62

;------------------------------------------------------------------
; Custom character shapes, copied over screen codes $80-$A2 by
; init_screen. Each character is 8 bytes, top row first; in each
; byte bit 7 is the leftmost pixel and a 1 bit is drawn in the
; foreground colour. For example the [+] box ($A1) is:
;
;     $FE  #######.
;     $82  #.....#.
;     $92  #..#..#.
;     $BA  #.###.#.
;     $92  #..#..#.
;     $82  #.....#.
;     $FE  #######.
;     $00  ........
;------------------------------------------------------------------
glyphs:
   .byte $00,$80,$C0,$E0,$F0,$F8,$FC,$FE   ; $80 logo: triangles,
   .byte $7F,$7F,$7F,$7F,$7F,$7F,$7F,$7F   ; $81   bars and blocks
   .byte $00,$01,$03,$07,$0F,$1F,$3F,$7F   ; $82
   .byte $FE,$FE,$FE,$FE,$FE,$FE,$FE,$FE   ; $83
   .byte $1F,$1F,$1F,$1F,$1F,$1F,$1F,$1F   ; $84
   .byte $FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF   ; $85
   .byte $F8,$F8,$F8,$F8,$F8,$F8,$F8,$F8   ; $86
   .byte $FF,$FF,$00,$00,$00,$00,$00,$00   ; $87
   .byte $FF,$FF,$FF,$FF,$0F,$0F,$0F,$0F   ; $88
   .byte $FF,$FF,$FF,$FF,$F0,$F0,$F0,$F0   ; $89
   .byte $00,$00,$00,$00,$00,$00,$FF,$FF   ; $8A
   .byte $0F,$0F,$0F,$0F,$FF,$FF,$FF,$FF   ; $8B
   .byte $F0,$F0,$F0,$F0,$FF,$FF,$FF,$FF   ; $8C
   .byte $03,$03,$03,$03,$03,$03,$03,$03   ; $8D
   .byte $FF,$FE,$FC,$F8,$F0,$E0,$C0,$80   ; $8E
   .byte $FF,$7F,$3F,$1F,$0F,$07,$03,$01   ; $8F
   .byte $C0,$C0,$C0,$C0,$C0,$C0,$C0,$C0   ; $90
   .byte $07,$07,$07,$07,$07,$07,$07,$07   ; $91
   .byte $E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0   ; $92
   .byte $00,$00,$00,$1F,$1F,$18,$18,$18   ; $93 top left corner
   .byte $00,$00,$00,$F8,$F8,$18,$18,$18   ; $94 top right corner
   .byte $18,$18,$18,$1F,$1F,$00,$00,$00   ; $95 bottom left corner
   .byte $18,$18,$18,$F8,$F8,$00,$00,$00   ; $96 bottom right corner
   .byte $00,$00,$00,$FF,$FF,$00,$00,$00   ; $97 horizontal line
   .byte $18,$18,$18,$18,$18,$18,$18,$18   ; $98 vertical line
   .byte $18,$18,$18,$1F,$1F,$18,$18,$18   ; $99 left tee
   .byte $18,$18,$18,$F8,$F8,$18,$18,$18   ; $9A right tee
   .byte $00,$00,$00,$FF,$FF,$18,$18,$18   ; $9B top tee
   .byte $18,$18,$18,$FF,$FF,$00,$00,$00   ; $9C bottom tee
   .byte $18,$18,$18,$FF,$FF,$18,$18,$18   ; $9D cross (spare)
   .byte $18,$3C,$7E,$FF,$18,$18,$18,$18   ; $9E scroll up arrow
   .byte $18,$18,$18,$18,$FF,$7E,$3C,$18   ; $9F scroll down arrow
   .byte $00,$E0,$9F,$81,$81,$81,$FF,$00   ; $A0 folder icon
   .byte $FE,$82,$92,$BA,$92,$82,$FE,$00   ; $A1 [+] box
   .byte $FE,$82,$82,$BA,$82,$82,$FE,$00   ; $A2 [-] box
