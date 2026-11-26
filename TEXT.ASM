;******************************************************************
; TEXT.ASM - the preview panel for text files: when the highlighted
; file is a .TXT or .MD file, its text is shown in the panel instead
; of a picture, with a scroll bar for files longer than the panel.
;
; HOW IT IS SHOWN
; The panel is 40 x 30 text cells (PREV_W x PREV_ROWS): 39 columns
; of text (TXT_W) and a scroll bar in the last column (TXT_SB), like
; the two lists. Normally those cells are see-through so the picture
; on layer 0 shows (see PNG.ASM); for text they get a solid colour
; (COL_TXT) and the picture underneath is hidden. preview_update
; makes them see-through again when the preview changes.
;
; READING THE FILE
; The whole file is read when it is chosen and laid out into lines
; of TXT_W characters, which are kept in banked RAM (banks TXT_BANK
; onwards, see below). Scrolling then just redraws the panel from
; there, without going back to the SD card. The file is read in
; blocks of up to 512 bytes with MACPTR (fast), using the PNG
; decoder's input buffer, which is free while text is being read.
; Files longer than TXT_MAX_LINES lines are cut off there.
;
; LAYING OUT THE TEXT
; Characters collect in tline, the line being built. When a line
; is full, it is broken after its last space (word wrap) and the
; word that didn't fit carries over to the next line. A word longer
; than the whole line is simply cut at the edge.
;
;   CR, LF or CR+LF  end a line (Windows, Unix and old Mac files)
;   Tab              spaces up to the next multiple of 4 columns
;   other control characters are left out
;   bytes $80-$FF    UTF-8: a character outside ASCII is several
;                    bytes, a first byte ($C0-$FF) and followers
;                    ($80-$BF). It is shown as one '?'.
;
; Markdown (.MD) files are shown as plain text, marks and all.
;
; STORING THE LINES
; Each finished line is stored as TXT_W screen codes (already
; converted from ASCII and padded with spaces, so drawing is just
; copying) in a 64-byte slot, 128 slots to an 8 KB bank:
;
;   line n is in bank TXT_BANK + n/128, at $A000 + (n mod 128)*64
;
; SCROLLING
; t_top is the first line shown. The scroll bar is bar BAR_TEXT in
; GUIMENU.ASM's scroll bar code, which also handles the mouse wheel
; and, when the text has the keyboard focus (Tab, or click the
; text), Up/Down, Page Up/Down and Home/End. That code calls
; text_set_scroll to move the text.
;******************************************************************

COL_TXT           = $1C           ; text preview: black on white,
                                  ;   like a sheet of paper
LFN_TXT           = 3             ; logical file number (PNG.ASM uses
                                  ;   3 too, but never at the same time)
TXT_TAB           = 4             ; tab stops every 4 columns
TXT_W             = PREV_W-1      ; 39 columns of text, then
TXT_SB            = PREV_X+TXT_W  ;   the scroll bar (column 75)
TXT_BANK          = 11            ; banks 11-26: the laid-out lines
TXT_BANKS         = 16            ;   (every X16 has at least 64 banks)
TXT_MAX_LINES     = TXT_BANKS*128 ; 2048 lines

.assert (TXT_TAB & (TXT_TAB-1)) = 0, error, "TXT_TAB must be a power of 2"
.assert TXT_W <= 64, error, "a line must fit its 64-byte slot"
.assert TXT_BANK > MAP_BANK, error, "text banks overlap the PNG decoder's"

.pushseg
.segment "BSS"
t_len:      .res 1                ; characters in tline so far
t_lines:    .res 2                ; lines stored so far
t_top:      .res 2                ; first line shown in the panel
t_n:        .res 2                ; line being drawn
t_r:        .res 1                ; panel row being drawn
t_eof:      .res 1                ; not 0 once the file has ended
t_err:      .res 1                ; not 0 if reading failed
t_cr:       .res 1                ; not 0 just after a CR (so a LF
                                  ;   straight after it is ignored)
t_ch:       .res 1                ; character waiting to be placed
t_brk:      .res 1                ; where a full line is broken
tline:      .res TXT_W            ; the line being built (ASCII)
pv_text:    .res 1                ; not 0 while the panel shows text
.popseg

;------------------------------------------------------------------
; text_show - read the text file whose record is in recbuf (its
; name is pv_namelen characters long) and show its first page in
; the preview panel
;------------------------------------------------------------------
text_show:
   stz t_len
   stz t_lines
   stz t_lines+1
   stz t_top
   stz t_top+1
   stz t_eof
   stz t_err
   stz t_cr
   stz in_left                    ; the input buffer is empty
   stz in_left+1
   lda #1                         ; the panel's cells are about to
   sta pv_text                    ;   be solid (see pv_clear_text)

   ; OPEN 3,8,3,"name"  (the DOS current folder is the open folder)
   lda pv_namelen
   ldx #<(recbuf+REC_NAME)
   ldy #>(recbuf+REC_NAME)
   jsr SETNAM
   lda #LFN_TXT
   ldx #DISK_DEVICE
   ldy #3
   jsr SETLFS
   jsr OPEN
   bcs @fail
   ldx #LFN_TXT
   jsr CHKIN
   bcs @fail

@read:
   jsr t_getc                     ; A = next byte, C = 1 at the end
   bcs @end
   jsr t_char                     ; lay it out; C = 1 if there is no
   bcc @read                      ;   room for more lines
   bra @close

@end:
   lda t_err                      ; couldn't read anything at all?
   beq :+
   lda t_lines
   ora t_len
   beq @fail
:  lda t_len                      ; the last line, if it has no CR
   beq @close                     ;   or LF after it
   jsr t_newline

@close:
   jsr CLRCHN
   lda #LFN_TXT
   jsr CLOSE
   jmp text_draw                  ; show the first page

@fail:
   jsr CLRCHN
   lda #LFN_TXT
   jsr CLOSE
   jsr pv_clear_text              ; back to the empty panel
   lda #<str_pv_open
   ldx #>str_pv_open
   jmp preview_message

;------------------------------------------------------------------
; t_getc - read the next byte of the file
; Out: C = 0 and A = the byte, or C = 1 if there are no more.
; Takes bytes from inbuf, refilling it from the file when it is
; empty (in_ptr = next byte, in_left = bytes left).
;------------------------------------------------------------------
t_getc:
   lda in_left
   ora in_left+1
   bne @take
   jsr t_refill
   bcs @none
@take:
   lda in_left                    ; one fewer left (16-bit)
   bne :+
   dec in_left+1
:  dec in_left
   lda (in_ptr)                   ; the byte (65C02: (zp) without Y)
   inc in_ptr
   bne :+
   inc in_ptr+1
:  clc
@none:
   rts

;------------------------------------------------------------------
; t_refill - read the next block of the file into inbuf
; Out: C = 0 if some bytes were read, C = 1 at the end (or an error)
;
; MACPTR reads up to 512 bytes at once. Not every device supports it
; (C = 1 back from it), and then CHRIN reads a byte at a time.
; READST afterwards gives the status: bit 6 ($40) set means the end
; of the file was reached (the bytes read are still good); any other
; bit means something went wrong.
;------------------------------------------------------------------
t_refill:
   lda t_eof
   bne @end                       ; nothing left to read
   lda #0                         ; 0 = as many as it likes (<= 512)
   ldx #<inbuf
   ldy #>inbuf
   clc                            ; C = 0: step through memory
   jsr MACPTR
   bcs @slow                      ; MACPTR not supported here
   stx in_left                    ; X/Y = how many were read
   sty in_left+1
@got:
   jsr READST
   tax
   and #$40
   sta t_eof                      ; the end: stop after these bytes
   txa
   and #$BF
   bne @error
   lda in_left
   ora in_left+1
   beq @end                       ; read nothing
   lda #<inbuf
   sta in_ptr
   lda #>inbuf
   sta in_ptr+1
   clc
   rts
@slow:                            ; one byte at a time, up to 255
   stz in_left
   stz in_left+1
:  jsr CHRIN
   ldx in_left
   sta inbuf,x
   inc in_left
   jsr READST
   bne @got
   lda in_left
   cmp #255
   bne :-
   bra @got
@error:
   lda #1
   sta t_err
   sta t_eof
@end:
   stz in_left
   stz in_left+1
   sec
   rts

;------------------------------------------------------------------
; t_char - lay out byte A from the file (see the top of this file)
; Out: C = 1 if there is no room for more lines
;------------------------------------------------------------------
t_char:
   cmp #$0D                       ; CR: end of line
   bne :+
   sta t_cr
   jmp t_newline
:  cmp #$0A                       ; LF: end of line, unless it is
   bne @not_lf                    ;   the second half of CR+LF
   lda t_cr
   stz t_cr
   bne :+
   jmp t_newline                  ; (too far for a branch)
:  clc
   rts
@not_lf:
   stz t_cr
   cmp #$09
   beq @tab
   cmp #$20
   bcc @skip                      ; other control characters
   cmp #$7F
   beq @skip                      ; DEL
   bcc t_put                      ; ordinary ASCII
   cmp #$C0
   bcc @skip                      ; UTF-8 follower byte
   lda #$3F                       ; UTF-8 first byte: one '?'
   bra t_put
@skip:
   clc
   rts
@tab:                             ; spaces to the next tab stop
   lda #$20
   jsr t_put
   bcs @done
   lda t_len
   and #TXT_TAB-1
   bne @tab
@done:
   rts

;------------------------------------------------------------------
; t_put - add ASCII character A to the line, wrapping the line
; first if it is full
; Out: C = 1 if there is no room for more lines
;------------------------------------------------------------------
t_put:
   ldx t_len
   cpx #TXT_W
   bcs @full
   sta tline,x                    ; room: just add it
   inc t_len
   clc
   rts

@full:
   cmp #$20                       ; a space where the line ends: the
   bne :+                         ;   line ends here, and the space
   jmp t_newline                  ;   isn't needed
:  sta t_ch

   ; find the line's last space (not counting one in column 0)
   ldx #TXT_W-1
@find:
   lda tline,x
   cmp #$20
   beq @split
   dex
   bne @find

   ; no space: the word is wider than the line, so cut it here
   jsr t_newline
   bcs @ret
   lda t_ch
   bra t_put                      ; (the new line has room)

@split:
   ; store the line up to the space; what comes after it (the start
   ; of the word that didn't fit) moves to the start of tline
   stx t_brk
   stx t_len                      ; store only the first X characters
   jsr t_newline
   bcs @ret
   ldx t_brk
   inx                            ; skip the space
   ldy #0
@move:
   cpx #TXT_W
   beq :+
   lda tline,x
   sta tline,y
   inx
   iny
   bra @move
:  sty t_len
   lda t_ch                       ; and now the character that
   bra t_put                      ;   didn't fit (there is room now)
@ret:
   rts

;------------------------------------------------------------------
; t_newline - store tline (t_len characters) as the next line in
; banked RAM, as screen codes padded with spaces, and start a new,
; empty line
; Out: C = 1 if there is no room for more lines
;------------------------------------------------------------------
t_newline:
   lda t_lines                    ; full already?
   cmp #<TXT_MAX_LINES
   lda t_lines+1
   sbc #>TXT_MAX_LINES
   bcs @ret                       ; yes (C = 1)
   lda t_lines
   ldx t_lines+1
   jsr t_line_ptr                 ; RAM_BANK and ptr -> its slot
   ldy #0
@char:
   cpy t_len
   beq @pad
   lda tline,y
   jsr ascii_to_screen            ; (changes X, keeps Y)
   sta (ptr),y
   iny
   bra @char
@pad:
   cpy #TXT_W
   beq :+
   lda #$20                       ; space
   sta (ptr),y
   iny
   bra @pad
:  stz RAM_BANK                   ; back to bank 0 for the KERNAL
   stz t_len
   inc t_lines
   bne :+
   inc t_lines+1
:  lda t_lines                    ; C = 1 if that was the last slot
   cmp #<TXT_MAX_LINES
   lda t_lines+1
   sbc #>TXT_MAX_LINES
@ret:
   rts

;------------------------------------------------------------------
; t_line_ptr - find line A/X (low/high) in banked RAM
; Out: RAM_BANK = TXT_BANK + n/128, ptr = $A000 + (n mod 128)*64
;------------------------------------------------------------------
t_line_ptr:
   pha
   and #$7F                       ; (n mod 128)*64: high byte =
   lsr                            ;   $A0 + (n mod 128)/4,
   lsr
   clc
   adc #>RAM_WIN
   sta ptr+1
   pla
   pha
   and #3                         ;   low byte = (n mod 4)*64
   asl
   asl
   asl
   asl
   asl
   asl
   sta ptr
   pla                            ; n/128 = high byte * 2, plus bit 7
   asl                            ;   of the low byte (into the carry
   txa                            ;   here, then rolled in)
   rol
   clc
   adc #TXT_BANK
   sta RAM_BANK
   rts

;------------------------------------------------------------------
; text_draw - draw the panel: PREV_ROWS lines from line t_top
; (blank rows after the last line), and the scroll bar
;------------------------------------------------------------------
text_draw:
   stz t_r
@row:
   lda t_r                        ; start of the panel row
   clc
   adc #PREV_TOP
   tay
   ldx #PREV_X
   jsr set_cursor
   lda t_top                      ; t_n = t_top + row
   clc
   adc t_r
   sta t_n
   lda t_top+1
   adc #0
   sta t_n+1
   lda t_n                        ; past the last line?
   cmp t_lines
   lda t_n+1
   sbc t_lines+1
   bcs @blank
   lda t_n
   ldx t_n+1
   jsr t_line_ptr
   ldy #0
:  lda (ptr),y                    ; copy the stored screen codes
   sta VERA_data0
   lda #COL_TXT
   sta VERA_data0
   iny
   cpy #TXT_W
   bne :-
   stz RAM_BANK
   bra @next
@blank:
   ldy #TXT_W
:  lda #$20
   sta VERA_data0
   lda #COL_TXT
   sta VERA_data0
   dey
   bne :-
@next:
   inc t_r
   lda t_r
   cmp #PREV_ROWS
   bne @row

   ldx #BAR_TEXT                  ; and the scroll bar
   jsr sb_load
   ldx #TXT_SB
   jmp draw_scrollbar

;------------------------------------------------------------------
; text_set_scroll - show the text from line sb_new (called by the
; scroll bar code in GUIMENU.ASM), redrawing if that is a change
;------------------------------------------------------------------
text_set_scroll:
   lda sb_new
   cmp t_top
   bne :+
   lda sb_new+1
   cmp t_top+1
   beq @same
:  lda sb_new
   sta t_top
   lda sb_new+1
   sta t_top+1
   jmp text_draw
@same:
   rts

;------------------------------------------------------------------
; pv_clear_text - if the panel shows text, make its cells blank and
; see-through again, so a picture (or the grey background) shows.
; If the text had the keyboard focus, the file list gets it.
;------------------------------------------------------------------
pv_clear_text:
   lda pv_text
   beq @done
   stz pv_text
   lda focus
   cmp #FOCUS_TEXT
   bne :+
   lda #FOCUS_FILES
   sta focus
:  ldy #PREV_TOP
@row:
   ldx #PREV_X
   jsr set_cursor
   lda #PREV_W
   sta remain
   lda #COL_PV_CLEAR
   sta cur_color
   jsr pad_field
   iny
   cpy #PREV_TOP+PREV_ROWS
   bne @row
@done:
   rts
