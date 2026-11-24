;******************************************************************
; DOS.ASM - talking to CMDR-DOS, the X16's SD card DOS (device 8)
;
; This uses the standard Commodore KERNAL file routines:
;   SETNAM  A = name length, X/Y = address of the name
;   SETLFS  A = logical file number (our own handle for the file),
;           X = device (8), Y = secondary address (channel)
;   OPEN    open it (carry set on error)
;   CHKIN   make logical file X the input for CHRIN
;   CHRIN   read one byte
;   READST  status: 0 = OK, bit 6 ($40) = end of file, others = error
;   CLRCHN  put input/output back to keyboard/screen
;   CLOSE   close logical file A
;
; Two special names are used:
;   "$" on channel 0    gives the directory listing
;   channel 15          is the command channel: the "name" is a DOS
;                       command (such as CD:GAMES) and reading from
;                       it gives the reply, e.g. "00, OK,00,00"
;
; NOTE: CMDR-DOS names are ASCII, not PETSCII ("Hello" comes back as
; $48 $65 $6C $6C $6F). The code here keeps them exactly as received.
;******************************************************************

LFN_DIR           = 2             ; logical file for listings/files
LFN_CMD           = 15            ; logical file for the command channel

;------------------------------------------------------------------
; dos_command - send a DOS command and read the reply
; In:  cmdbuf = the command, cmdlen = its length
; Out: dos_status = first two characters of the reply (e.g. "00")
;      C = 1 if the command failed
;------------------------------------------------------------------
dos_command:
   lda cmdlen                     ; the command is the "file name"
   ldx #<cmdbuf
   ldy #>cmdbuf
   jsr SETNAM
   lda #LFN_CMD
   ldx #DISK_DEVICE
   ldy #15                        ; channel 15 = command channel
   jsr SETLFS
   jsr OPEN                       ; opening it sends the command
   bcs @fail

   ; read the reply: two digit code, then text up to a RETURN
   ldx #LFN_CMD
   jsr CHKIN
   bcs @close
   jsr CHRIN
   sta dos_status
   jsr CHRIN
   sta dos_status+1
@drain:                           ; read (and ignore) the rest
   jsr READST
   bne @close
   jsr CHRIN
   cmp #13
   bne @drain
@close:
   jsr CLRCHN
   lda #LFN_CMD
   jsr CLOSE
   ; success is "00". ORing the two digits gives "0" ($30) only if
   ; both are "0".
   lda dos_status
   ora dos_status+1
   cmp #$30
   bne @fail
   clc
   rts
@fail:
   sec
   rts

;------------------------------------------------------------------
; read_dir - read the directory listing of DOS's current folder
;
; Out: files       -> records in FILE_BANK, file_count of them,
;                     sorted into file_order
;      sub-folders -> records in TDIR_BANK, tdir_count of them,
;                     sorted into tdir_order
;      dir_error   =  1 if the listing couldn't be read, else 0
;
; The listing arrives in the same format as a BASIC program, which
; is why LOAD"$",8 followed by LIST shows it:
;
;   2 bytes   load address (ignored)
;   then for each line:
;     2 bytes  link to the next line ($0000 = end of the listing)
;     2 bytes  line number (here it is the file size in blocks)
;     text     e.g.  "HELLO.PRG"        PRG
;     $00      end of the line
;
; The first line is the disk name (skipped) and the last one is
; "BLOCKS FREE." (ignored by parse_line because it has no quotes).
;------------------------------------------------------------------
read_dir:
   stz file_count
   stz tdir_count
   lda #1                         ; assume the worst until the
   sta dir_error                  ;   listing starts arriving

   ; OPEN 2,8,0,"$"
   lda #1
   ldx #<dir_name
   ldy #>dir_name
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

   jsr CHRIN                      ; skip the load address
   jsr CHRIN
   jsr READST
   bne @close                     ; nothing there: error
   stz dir_error
   lda #1
   sta first_line

@line:
   jsr CHRIN                      ; link to the next line
   sta tmp
   jsr CHRIN
   ora tmp
   beq @close                     ; $0000 = end of listing
   jsr READST
   bne @close
   jsr CHRIN                      ; line number (block count)
   jsr CHRIN

   ; read the text of the line into linebuf
   stz line_len
@char:
   jsr CHRIN
   cmp #0
   beq @eol                       ; $00 = end of the line
   ldx line_len
   cpx #255
   beq :+                         ; buffer full: drop the rest
   sta linebuf,x
   inc line_len
:  jsr READST
   beq @char
   bra @close                     ; error or end of file mid-line
@eol:
   ldx line_len
   stz linebuf,x                  ; 0-terminate it

   lda first_line                 ; first line is the disk name:
   beq :+                         ;   skip it
   stz first_line
   bra @next
:  jsr parse_line                 ; pick out the name and type
@next:
   jsr READST
   beq @line

@close:
   jsr CLRCHN
   lda #LFN_DIR
   jsr CLOSE

   ; sort the files by name
   lda #FILE_BANK
   sta sort_bank
   lda #<file_order
   sta optr
   lda #>file_order
   sta optr+1
   ldx file_count
   jsr sort_records

   ; and the sub-folders
   lda #TDIR_BANK
   sta sort_bank
   lda #<tdir_order
   sta optr
   lda #>tdir_order
   sta optr+1
   ldx tdir_count
   jmp sort_records

dir_name: .byte "$"

;------------------------------------------------------------------
; parse_line - pick the name and type out of one listing line in
; linebuf, and store it as a file or a sub-folder. Lines look like:
;
;     "GAMES"            DIR
;     "HELLO.PRG"        PRG
;
; The name is between the quotes; the first letter after the
; spaces that follow tells us the type (D = folder). Lines with no
; quoted name are ignored.
;------------------------------------------------------------------
parse_line:
   ldx #0                         ; X = position in linebuf
@find:                            ; look for the opening quote
   lda linebuf,x
   beq @ignore                    ; none: not a file line
   inx
   cmp #$22                       ; "
   bne @find

   ldy #0                         ; Y = position in namebuf
@copy:                            ; copy up to the closing quote
   lda linebuf,x
   beq @ignore                    ; no closing quote: ignore
   inx
   cmp #$22
   beq @endname
   cpy #NAME_MAX
   bcs @copy                      ; too long: drop the extra
   sta namebuf,y
   iny
   bra @copy
@endname:
   lda #0
   sta namebuf,y                  ; 0-terminate the name
   sty namelen
   cpy #0
   beq @ignore                    ; empty name

@spaces:                          ; skip the spaces after the name
   lda linebuf,x
   inx
   cmp #$20
   beq @spaces
   and #$DF                       ; upper case
   cmp #$44                       ; 'D' -> "DIR" -> a folder
   beq @dir

   ; ---- a file ----
   ; If the list is full, an ordinary file is dropped, but a program
   ; takes the place of an ordinary file already in the list, so
   ; programs are never lost (they are what we are here to run).
   jsr name_to_recbuf
   jsr is_prg
   bcc @not_prg
   lda #FLAG_PRG                  ; mark programs
   sta recbuf+REC_FLAGS
   lda file_count
   cmp #MAX_FILES
   bcc @add_file                  ; room left: add it
   jsr find_non_prg               ; full: A = an ordinary file to
   bcs @ignore                    ;   replace (none: all programs)
   bra @store_file
@not_prg:
   lda file_count
   cmp #MAX_FILES
   bcs @ignore                    ; list full: drop it
@add_file:
   lda file_count                 ; store as the next file record
   inc file_count                 ;   (INC doesn't change A)
@store_file:
   jsr file_ptr                   ; A = record number to store at
   jsr store_rec
@ignore:
   rts

@dir:
   ; ---- a folder ----
   ; skip "." (this folder) and ".." (the parent)
   lda namebuf
   cmp #$2E                       ; '.'
   bne @add_dir
   lda namebuf+1
   beq @ignore                    ; "."
   cmp #$2E
   bne @add_dir
   lda namebuf+2
   beq @ignore                    ; ".."
@add_dir:
   lda tdir_count
   cmp #MAX_TDIRS
   bcs @ignore                    ; list full
   jsr name_to_recbuf
   lda tdir_count                 ; store as the next sub-folder
   jsr tdir_ptr
   jsr store_rec
   inc tdir_count
   rts

;------------------------------------------------------------------
; find_non_prg - find a file record that is not a program
; Out: C = 0 and A = its record number, or C = 1 if every file in
;      the list is a program
;------------------------------------------------------------------
find_non_prg:
   stz scan_i
@loop:
   lda scan_i
   jsr file_ptr                   ; ptr -> record, bank switched
   ldy #REC_FLAGS
   lda (ptr),y
   stz RAM_BANK
   and #FLAG_PRG
   beq @found                     ; not a program
   inc scan_i
   lda scan_i
   cmp file_count
   bne @loop
   sec                            ; all programs
   rts
@found:
   lda scan_i
   clc
   rts

;------------------------------------------------------------------
; name_to_recbuf - clear recbuf and copy the name from namebuf
;------------------------------------------------------------------
name_to_recbuf:
   ldx #63
:  stz recbuf,x
   dex
   bpl :-
   ldx #0
:  lda namebuf,x
   sta recbuf+REC_NAME,x
   beq :+                         ; copied the terminating 0
   inx
   bra :-
:  rts

;------------------------------------------------------------------
; is_prg - does the name in namebuf end in ".PRG" (any case)?
; Out: C = 1 if it does
; ASCII upper and lower case letters differ only in bit 5 ($20), so
; AND #$DF turns either into upper case before comparing.
;------------------------------------------------------------------
is_prg:
   lda namelen
   cmp #4
   bcc @no                        ; too short
   tax                            ; X = length, so namebuf-4,X is
   lda namebuf-4,x                ;   the 4th character from the end
   cmp #$2E                       ; '.'
   bne @no
   lda namebuf-3,x
   and #$DF
   cmp #$50                       ; 'P'
   bne @no
   lda namebuf-2,x
   and #$DF
   cmp #$52                       ; 'R'
   bne @no
   lda namebuf-1,x
   and #$DF
   cmp #$47                       ; 'G'
   bne @no
   sec
   rts
@no:
   clc
   rts

.pushseg
.segment "BSS"
first_line: .res 1                ; 1 while reading the disk name line
scan_i:     .res 1                ; record being checked by find_non_prg
line_len:   .res 1                ; characters in linebuf
.popseg
