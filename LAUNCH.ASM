;******************************************************************
; LAUNCH.ASM - load and run the chosen .PRG
;
; THE PROBLEM
; Most X16 programs load at $0801, exactly where this program is
; sitting, so we can't simply load them and jump: the load would
; overwrite the code doing the loading. BASIC programs also need
; BASIC's own pointers set up, which only BASIC's LOAD does.
;
; SO THERE ARE TWO WAYS TO START A PROGRAM
;
; 1. Load address $0801 (BASIC programs, and machine code programs
;    that start with a "10 SYS 2061" line, which is nearly all X16
;    programs): let BASIC do it. The X16 BASIC "DOS wedge" command
;
;        ^NAME            (^ is the up-arrow key)
;
;    loads NAME and runs it. We use the old Commodore "dynamic
;    keyboard" trick to type it:
;      - reset the screen and print  ^NAME  on row 2
;      - move the cursor to the top (HOME)
;      - put a RETURN into the keyboard buffer
;      - warm start BASIC, which prints READY. on row 1, leaving the
;        cursor on row 2, and then reads the RETURN - so BASIC
;        executes the line we printed, just as if it had been typed.
;    The current DOS directory is already the program's folder, so
;    the program also finds any data files it loads.
;
; 2. Any other load address: copy a tiny loader to $0400 (memory
;    that BASIC programs don't use), and run it. It loads the file
;    to the address in its header and JMPs there.
;******************************************************************

LOADER_ADDR       = $0400

;------------------------------------------------------------------
; launch_file - run a program
; In: A = position in the sorted file list
; Only returns (with an error message shown) if the file can't be
; opened.
;------------------------------------------------------------------
launch_file:
   tax
   lda file_order,x               ; record number of the file
   jsr file_ptr
   jsr load_rec                   ; recbuf = its record

   ; work out the length of the name
   ldx #0
:  lda recbuf+REC_NAME,x
   beq :+
   inx
   bra :-
:  stx namelen

   ; read the first two bytes of the file: its load address
   jsr read_load_address
   bcc :+
   jmp launch_failed
:
   lda load_addr                  ; is it $0801?
   cmp #$01
   bne launch_binary
   lda load_addr+1
   cmp #$08
   bne launch_binary
   ; yes: fall through to launch_basic

;------------------------------------------------------------------
; launch_basic - start a $0801 program by having BASIC "type"
; ^NAME for us (see the notes at the top of this file).
;------------------------------------------------------------------
launch_basic:
   jsr restore_system             ; normal screen, cursor at the top
   lda #13                        ; two RETURNs: move to row 2
   jsr CHROUT
   lda #13
   jsr CHROUT
   lda #$5E                       ; up arrow: DOS wedge "load and run"
   jsr CHROUT
   ldx #0                         ; then the name
:  lda recbuf+REC_NAME,x
   beq :+
   jsr typeable_char
   phx
   jsr CHROUT
   plx
   inx
   bra :-
:  lda #$13                       ; HOME: cursor to the top left
   jsr CHROUT
   lda #13                        ; queue a RETURN keypress
   jsr KBDBUF_PUT
   clc                            ; warm start BASIC. It never comes
   jmp ENTER_BASIC                ;   back here.

;------------------------------------------------------------------
; typeable_char - make a name character safe to "type"
;
; BASIC reads the line back off the screen, and in the normal
; character set that can only give upper case letters. CMDR-DOS
; ignores case when it looks for a file, so lower case letters are
; simply sent as upper case. Anything that can't be typed becomes
; '?', which DOS treats as "any character".
;------------------------------------------------------------------
typeable_char:
   cmp #$61                       ; below 'a': check for control codes
   bcc :+
   cmp #$7B                       ; above 'z': can't be typed
   bcs @wild
   and #$DF                       ; a-z -> A-Z
   rts
:  cmp #$20
   bcs :+                         ; normal printable character
@wild:
   lda #$3F                       ; '?'
:  rts

;------------------------------------------------------------------
; launch_binary - start a program that loads somewhere other than
; $0801, using the loader at $0400.
;------------------------------------------------------------------
launch_binary:
   ; copy the loader code to $0400
   ldx #0
:  lda loader_image,x
   sta LOADER_ADDR,x
   inx
   cpx #loader_end-loader_start
   bne :-
   ; give it the file name...
   ldx #0
:  lda recbuf+REC_NAME,x
   sta ld_name,x
   inx
   cpx #NAME_MAX+1
   bne :-
   lda namelen
   sta ld_namelen
   ; ...and change its JMP $FFFF into JMP <load address>
   lda load_addr
   sta ld_jump+1
   lda load_addr+1
   sta ld_jump+2

   jsr restore_system
   jmp loader_start               ; never comes back

;------------------------------------------------------------------
; read_load_address - read the first two bytes (the load address)
; of the file named in recbuf into load_addr.
; Out: C = 1 if the file couldn't be read
;------------------------------------------------------------------
read_load_address:
   lda namelen                    ; OPEN 2,8,0,"name"
   ldx #<(recbuf+REC_NAME)
   ldy #>(recbuf+REC_NAME)
   jsr SETNAM
   lda #LFN_DIR
   ldx #DISK_DEVICE
   ldy #0
   jsr SETLFS
   jsr OPEN
   bcs @close
   ldx #LFN_DIR
   jsr CHKIN
   bcs @close
   jsr CHRIN                      ; low byte
   sta load_addr
   jsr CHRIN                      ; high byte
   sta load_addr+1
   jsr READST
   and #$BF                       ; end of file ($40) is fine
   cmp #1                         ; C = 1 if any other status bit
@close:
   php                            ; keep the carry (error flag)
   jsr CLRCHN
   lda #LFN_DIR
   jsr CLOSE
   plp
   rts

;------------------------------------------------------------------
; launch_failed - show an error on the status line instead of the
; path (the next folder change puts the path back)
;------------------------------------------------------------------
launch_failed:
   ldx #LEFT_X+2
   ldy #STATUS_ROW
   jsr set_cursor
   lda #COL_ERROR
   sta cur_color
   lda #RIGHT_X-(str_hint_end-str_hint)-LEFT_X-3
   sta remain
   lda #<str_load_error
   sta sptr
   lda #>str_load_error
   sta sptr+1
   jsr put_string
   jmp pad_field

str_load_error: .byte "Unable to open that program", 0

.pushseg
.segment "BSS"
load_addr: .res 2                 ; the file's load address
.popseg

;------------------------------------------------------------------
; The loader
;
; These bytes are stored here in the program (loader_image) but are
; assembled as if they were at $0400 (".org LOADER_ADDR"), because
; launch_binary copies them there before running them. ".reloc"
; afterwards goes back to normal addressing.
;------------------------------------------------------------------
loader_image:
.org LOADER_ADDR
loader_start:
   lda ld_namelen                 ; LOAD "name",8,1
   ldx #<ld_name
   ldy #>ld_name
   jsr SETNAM
   lda #1
   ldx #DISK_DEVICE
   ldy #1                         ; 1 = load to the address in the file
   jsr SETLFS
   lda #0                         ; 0 = load (1 would be verify)
   jsr LOAD
   bcs ld_fail                    ; load failed
   ; Push the address of ld_fail (minus 1, as JSR does), so that if
   ; the program ends with RTS it returns to BASIC's READY. prompt.
   lda #>(ld_fail-1)
   pha
   lda #<(ld_fail-1)
   pha
ld_jump:
   jmp $FFFF                      ; $FFFF is replaced by the load address
ld_fail:
   clc                            ; warm start BASIC
   jmp ENTER_BASIC
ld_namelen: .byte 0               ; filled in by launch_binary
ld_name:    .res NAME_MAX+1
loader_end:
.reloc
