;----------------------------------------------------
;      Disassembly of the file Cliffhanger ROMs
;        by Jeff Kulczycki and Robert Dinapoli
;                   Apr 12, 2000
;----------------------------------------------------
;                                                                     
;----------------------------------------------------
;    RAM VARIABLES
;----------------------------------------------------
;    Address      Description
;----------------------------------------------------
;   E000 - E007   High Score 1
;   E008 - E00F   High Score 2
;   E010 - E017   High Score 3
;   E018 - E01F   High Score 4 
;   E020 - E027   High Score 5
;   E028 - E02F   High Score 6
;   E030 - E037   High Score 7
;   E038 - E03F   High Score 8
;   E040 - E047   High Score 9
;   E048 - E04F   High Score 10
;   E050 - E052   High Score 1 Initials
;   E053 - E057   High Score 1
;   E058 - E05A   High Score 2 Initials
;   E05B - E05F   High Score 2
;   E060 - E062   High Score 3 Initials           
;   E063 - E067   High Score 3
;   E068 - E06A   High Score 4 Initials
;   E06B - E06F   High Score 4
;   E070 - E072   High Score 5 Initials
;   E073 - E077   High Score 5
;   E078 - E07A   High Score 6 Initials
;   E07B - E07F   High Score 6
;   E080 - E082   High Score 7 Initials
;   E083 - E087   High Score 7
;   E088 - E08A   High Score 8 Initials
;   E08B - E08F   High Score 8
;   E090 - E092   High Score 9 Initials
;   E093 - E097   High Score 9
;   E098 - E09A   High Score 10 Initials
;   E09B - E09F   High Score 10
;   E0A0 - E0A2   Total Plays
;   E0A3 - E0A4   Left Coin Slot Total
;   E0A5 - E0A6   Right Coin Slot Total
;   E0A7          Bookkeeping Counter (Coins)
;   E0A8 - E0AA   Total Play Time Seconds
;   E0AB - E0AD   Longest Game Seconds
;   E0AE          Shortest Game Seconds
;   E0AF          Highest Scene
;   E0B0          Bookkeeping Counter (Times)
;   E0B1 - E0B2   Range of Scores:    0 - 100K
;   E0B3 - E0B4   Range of Scores: 100K - 200K
;   E0B5 - E0B6   Range of Scores: 200K - 300K
;   E0B7 - E0B8   Range of Scores: 300K - 400K
;   E0B9 - E0BA   Range of Scores: 400K - 500K
;   E0BB - E0BC   Range of Scores: 500K - 600K
;   E0BD - E0BE   Range of Scores: 600K - 700K
;   E0BF - E0C0   Range of Scores: 700K - 800K
;   E0C1 - E0C2   Range of Scores: 800K - 900K
;   E0C3 - E0C4   Range of Scores: 900K - 1000K
;   E0C5 - E0C6   Range of Scores: 1000K - 1100K
;   E0C7 - E0C8   Range of Scores: 1100K - 1200K
;   E0C9 - E0CA   Range of Scores: 1200K - 1300K
;   E0CB - E0CC   Range of Scores: 1300K - 1400K
;   E0CD - E0CE   Range of Scores: 1400K+     
;   E0CF          Bookkeeping Counter (Range of Score)
;   E0D0 - E0D1   Times 0 - 1 minutes 
;   E0D2 - E0D3   Times 1 - 2 minutes
;   E0D4 - E0D5   Times 2 - 3 minutes 
;   E0D6 - E0D7   Times 3 - 4 minutes
;   E0D8 - E0D9   Times 4 - 5 minutes 
;   E0DA - E0DB   Times 5 - 6 minutes
;   E0DC - E0DD   Times 6 - 7 minutes 
;   E0DE - E0DF   Times 7 - 8 minutes
;   E0E0 - E0E1   Times 8 - 9 minutes 
;   E0E2 - E0E3   Times 9 - 10 minutes
;   E0E4 - E0E5   Times 10 - 11 minutes 
;   E0E6 - E0E7   Times 11 - 12 minutes
;   E0E8 - E0E9   Times 12 - 13 minutes 
;   E0EA - E0EB   Times 13 - 14 minutes
;   E0EC - E0ED   Times 14+ minutes
;   E0EE          Bookkeeping Counter (Range of Times)
;   E0EF - E0F0   Scene 1 Totals
;   E0F1 - E0F2   Scene 2 Totals
;   E0F3 - E0F4   Scene 3 Totals
;   E0F5 - E0F6   Scene 4 Totals
;   E0F7 - E0F8   Scene 5 Totals
;   E0F9 - E0FA   Scene 6 Totals
;   E0FB - E0FC   Scene 7 Totals
;   E0FD - E0FE   Scene 8 Totals
;   E0FF          Bookkeeping Counter (Scene Totals)
;   E100 - E10B   ? 
;   E10D          Bookkeeping Counter <--?
;   E112          LDPlayer Pulse, kick when frame count is received
;   E113          unknown
;   E114          unknown
;   E115          Graphics Status (00h = Available, 4Ch = Write Requested)
;   E116 - E118   Odd  Frame Count Target
;   E119 - E11B   Even Frame Count Target
;   E11C - E11E   Frame Count Even
;   E11F - E121   Frame Count Odd
;   E122          errors?
;   E123          errors?
;   E126  .0      unknown
;         .1      LDPlayer Status      0=Not BUSY, 1=BUSY
;         .2      unknown
;         .3      unknown
;         .4      PAUSE Status         0=Not PAUSED, 1=PAUSED
;         .5      Audio Channel Right  0=ON, 1=OFF
;         .6      Audio Channel Left   0=ON, 1=OFF
;   E127 - E12A   Temporary Aritmetic Location E127:MSB...E12A:LSB
;   E12F - E136   Graphics Chip Control Registers
;   E137          Graphics index
;   E138          Graphics index
;   E13B - E13C
;   E13E - E13F   Hardware Errors
;   E140 - E145   Timer?
;   E15A          unknown
;   E15B          unknown
;   E15E          unknown
;   E16E - E16F   LaserDisc Errors
;   E170 - E172   Frame Count Slop Error
;   E174          unknown
;   E17A          Seconds Timer
;   E180 - E182   Frame Number compare 
;   E183          BANK 0:  ZPU Switches  1,2
;   E184 - E185   BANK 0:  ZPU Switches  1,2   Debounce
;   E186          BANK 1:  DIP Switches 28-35
;   E187 - E188   BANK 1:  DIP Switches 28-35  Debounce
;   E189          BANK 2:  DIP Switches 20-27
;   E18A - E18B   BANK 2:  DIP Switches 20-27  Debounce
;   E18C          BANK 3:  DIP Switches 12-19
;   E18D - E18E   BANK 3:  DIP Switches 12-19  Debounce
;   E18F          BANK 4:  DIP Switches  4-11
;   E190 - E191   BANK 4:  DIP Switches  4-11  Debounce
;   E192          BANK 5:  Button Data 
;   E193 - E194   BANK 5:  Button Data Debounce Buffer
;   E195          BANK 6:  Joystick Data
;   E196 - E197   BANK 6:  Joystick Data Debounce Buffer
;   E198          BANK 7:  unknown
;   E199 - E19A   BANK 7:  unknown  Debounce
;   E19B          BANK 8:  unknown
;   E19C - E19D   BANK 8:  unknown  Debounce
;   E19E          BANK 9:  unknown 
;   E19F - E1A0   BANK 9:  unknown  Debounce
;   E1A1          Coins Inserted Left
;   E1A2          Coins Inserted Right
;   E1A3          Coins?
;   E1A6
;   E1A8          Number of Credits 
;   E1A9          Player Number
;   E1AA - E1AD   Score
;   E1AE          Lives remaining
;   E1B1          unknown - frame?
;   E1B6          Current Scene Number
;   E1BB - E1BC   Scene Pointer
;   E1C4 - E1C6   Minutes (BCD) Real-time Game Play Timer
;   E1C7 - E1E4   Swap with E1A7-E1C6
;   E1E5          ?
;   E1E6          Service Mode selection
;----------------------------------------------------
;   E000 - E800   Bookkeeping RAM ?
;   E800-         Scratch RAM ?
;----------------------------------------------------
;
;----------------------------------------------------
;               BEGIN FIRST ROM 0000-1FFF
;----------------------------------------------------
        org     0000h
        CPU     = Z180
        globals on

;----------------------------------------------------
;         Definitions
;----------------------------------------------------
;  Pixel Byte Colors
;     0h   TRANSPARENT 
;     1h   BLACK       
;     2h   MED GREEN
;     3h   LT GREEN
;     4h   BLUE         
;     5h   LT BLUE   
;     6h   DK RED
;     7h   CYAN
;     8h   MED RED
;     9h   PINK
;     Ah   DK YELLOW
;     Bh   LT YELLOW
;     Ch   DK GREEN
;     Dh   PURPLE
;     Eh   GRAY
;     Fh   WHITE




;----------------------------------------------------
;                   Reset
;----------------------------------------------------
L0000:  IN      A,(055h)        ; Read Graphics Byte
        LD      SP,0F000h       ; Set Stack Pointer
        DI                      ; Disable Interrupts
        IM      1               ; Interrupt Mode 1
        JP      L0300           ; Start Initialization
L000B:  JP      L0128           ; Begin Game


;----------------------------------------------------
;        ROM 0 - Copyright location
;----------------------------------------------------
L000E: TEXT "COPYRIGHT STERN ELECTRONICS, INC."

        DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        DB   0FFh, 0FFh, 0FFh, 0FFh






;----------------------------------------------------
;             IM 1 INTERRUPT JUMP POINT
;----------------------------------------------------
;    Read in Frame Counter from LDPlayer Interface
;       E11C-E11E = Even Frame Count
;       E11F-E121 = Odd Frame Count
;----------------------------------------------------
L0038:  OUT     (057h),A        ;
        PUSH    AF              ; Save AF Register
        PUSH    HL              ; Save HL Register
        LD      HL,0E112h       ; LDPlayer Pulse
        INC     (HL)            ; Kick the LDPlayer Pulse
        BIT     0,(HL)          ; Check if Pulse even or odd
        LD      HL,0E11Ch       ; Load Frame Count Spot for Even
        JP      Z,L004B         ; Skip Odd Count
        LD      HL,0E11Fh       ; Load Frame Count Spot for Odd
L004B:  IN      A,(052h)        ; Retrieve MSB Frame Count byte
        LD      (HL),A          ; Store in Frame Count Spot
        CPL                     ; Reverse all bits
        AND     0F8h            ; Is LDPlayer BUSY?
        JP      NZ,L005C        ; Yes, LDPlayer BUSY so skip
        INC     HL              ; Point to next location
        IN      A,(051h)        ; Retrieve next Frame Count byte
        LD      (HL),A          ; Store in Frame Count Spot
        INC     HL              ; Point to next location
        IN      A,(050h)        ; Retrieve LSB Frame Count byte
        LD      (HL),A          ; Store in Frame Count Spot
L005C:  EI                      ; Enable Interrupts
        IN      A,(053h)        ;
        EX      (SP),IX         ;
        EX      (SP),IX         ;
        POP     HL              ; Restore HL Register
L0064:  POP     AF              ; Restore AF Register
        RET                     ; Return







;----------------------------------------------------
;         NMI Non-Maskable Interrupt Routine
;      Occurs every 1 second
;----------------------------------------------------
L0066:  PUSH    AF              ; Save AF Register
        EX      AF,AF'          ; Get AF' Register
        PUSH    AF              ; Save AF' Register
        PUSH    BC              ; Save BC Register
        PUSH    DE              ; Save DE Register
        PUSH    HL              ; Save HL Register
L006C:  PUSH    IX              ; Save IX Reigster
        LD      A,I             ; Are interrupts disabled?
        JP      PO,L0076        ; Yes, so skip Frame Count Retrieval
        CALL    L6631           ; Retrieve Frame Count 
L0076:  CALL    L2465           ; Read Joystick and Button Data
        CALL    L1162           ; Check Coin Slots
        CALL    L0103           ; Update Real-time Game Play Tiemr

        LD      A,(0E125h)      ;
L0082:  OR      A               ;
        LD      A,(0E113h)      ;
        RES     1,A             ;
        LD      B,A             ;
        LD      A,(0E114h)      ;
        RES     0,A             ;
        JR      Z,L0098         ;       
        LD      HL,0E125h       ;
        DEC     (HL)            ;
        SET     0,A             ;
        SET     1,B
L0098:  OUT     (046h),A
        LD      (0E114h),A
        LD      A,B
        OUT     (064h),A
        LD      (0E113h),A
        LD      A,(0E110h)
        OR      A
        LD      A,(0E113h)
        RES     2,A
        LD      B,A
        LD      A,(0E114h)
        RES     1,A
        JR      Z,L00BC                 
        LD      HL,0E110h
        DEC     (HL)
        SET     1,A
        SET     2,B
L00BC:  OUT     (046h),A
        LD      (0E114h),A
        LD      A,B
        OUT     (064h),A
        LD      (0E113h),A
;----------------------------------------------------
;       Flash LED to show board is operational
;----------------------------------------------------
        LD      HL,0E111h
        INC     (HL)
        BIT     0,(HL)          ; Test odd/even
        JR      Z,L00D3         ; Even so skip ahead                   
        OUT     (06Fh),A        ; Turn LED on
        JR      L00D5           ; Skip ahead
L00D3:  OUT     (06Eh),A        ; Turn LED off
;----------------------------------------------------
;            Check for Game Tilted
;----------------------------------------------------
L00D5:  LD      A,(0E193h)      ; Get Button Data
        BIT     7,A             ; Is game Tilted?
        CALL    NZ,L2509        ; Yes, do Tilt scene
;----------------------------------------------------
;       Process Graphics Chip Write Requests
;----------------------------------------------------
        IN      A,(055h)        ; Read Graphics Byte
        LD      A,(0E115h)      ; Get Graphics Status
        CP      04Ch            ; Is there a Write Request?
        CALL    Z,L2316         ; Yes, so Write Graphics Registers

        LD      A,(0E126h)      ; Get Control Register
        BIT     0,A             ;
        JP      Z,L00F4         ;
        LD      A,I             ;
        CALL    PE,L1DFA        ;
L00F4:  POP     IX              ; Restore IX Register
        POP     HL              ; Restore HL Register
        POP     DE              ; Restore DE Register
        POP     BC              ; Restore BC Register
        POP     AF              ; Restore AF' Register
        EX      AF,AF'          ; Save AF'
        POP     AF              ; Restore AF Register
        RETN                    ; Return from NMI









;----------------------------------------------------
;            Get ?
;----------------------------------------------------
L00FE:  IN      A,(055h)        ; Read Graphics Byte
        POP     AF              ;
        RETN                    ; Return
                               






;----------------------------------------------------
;         Update Real-time Game Play Timer
;----------------------------------------------------
;         E17A       Seconds Counter
;         E1C4-E1C6  Minutes (BCD)
;---------------------------------------------------- 
L0103:  LD      A,(0E126h)      ; Get Control Register
        BIT     0,A             ; Check if game is playing
        RET     NZ              ; Game not playing so leave
        LD      HL,0E17Ah       ; Get Number of seconds
        DEC     (HL)            ; Count down seconds
        RET     NZ              ; Not zero so return
        LD      A,03Ch          ; A = 60 seconds
        LD      (HL),A          ; Reset second counter
        LD      HL,0E1C6h       ; Point to Timer
        LD      A,(HL)          ; Get minutes (ones)
        ADD     A,001h          ; Add one minute
        DAA                     ; Make BCD
        LD      (HL),A          ; Store minute (ones)
        RET     NZ              ; Return if not rolled
        DEC     HL              ; Point to minutes (tens)
        LD      A,(HL)          ; Get minutes (tens)
        ADD     A,001h          ; Increment tens spot
        DAA                     ; Make BCD
        LD      (HL),A          ; Store minutes (tens)
        RET     NZ              ; Return if not rolled
        DEC     HL              ; Point to minutes (hundreds)
        LD      A,(HL)          ; Get minutes (hundreds)
        ADD     A,001h          ; Increment hundreds spot
        DAA                     ; Make BCD
        LD      (HL),A          ; Store minutes (hundreds)
        RET                     ; Return







;----------------------------------------------------
;         Game Power up and Initialization 
;----------------------------------------------------
;  Set Stack Pointer, Clear out Scratch RAM E800-EFFF 
;---------------------------------------------------- 
L0128:  LD      SP,0F000h       ; Set Stack Pointer
;----------------------------------------------------
;              Clear out RAM E800-EFFF 
;---------------------------------------------------- 
        XOR     A               ; A = 0
        LD      BC,007FFh       ; RAM length 7FFh
        LD      DE,0E801h       ; Setup Loop
        LD      HL,0E800h       ; Start of RAM
        LD      (HL),A          ; Clear out RAM spot
        LDIR                    ; Loop until all RAM cleared
;----------------------------------------------------
;              Clear out RAM E10E-E7FF 
;----------------------------------------------------
        XOR     A               ; A = 0
        LD      BC,007FFh       ; RAM length 7FFh
        LD      DE,0E10Fh       ; Setup Loop
        LD      HL,0E10Eh       ; Start of RAM
        LD      (HL),A          ; Clear out RAM spot
        LDIR                    ; Loop until all RAM cleared
         
;----------------------------------------------------
;              Clear out variables 
;----------------------------------------------------
        LD      (0E1A8h),A      ; Zero out Number of Credits
        LD      (0E113h),A      ; 
        OUT     (06Eh),A        ; 
        LD      (0E12Eh),A      ; 
;----------------------------------------------------
;            Set Game Register settings
;----------------------------------------------------
        SET     5,A             ; Start with Audio Right Disabled 
        SET     6,A             ; Start with Audio Left Disabled
        SET     0,A             ; 
        SET     3,A             ; 
        LD      (0E126h),A      ; Save Control Register
        LD      A,014h          ; A = 20
        LD      (0E121h),A      ; 
        CALL    L24A7           ; Read DIP Switches
        CALL    L1F05           ; Clear out Player Data
        LD      A,(0E18Ch)      ; Get DIP Switches 12-19
        BIT     0,A             ; Check if Service Mode Enable
        JP      NZ,L40FE        ; Service Mode enabled, jump ahead
        EI                      ; Enable Interrupts
        JP      L053D           ; Goto PLEASE STAND BY startup





;----------------------------------------------------
;                 Garbage
;----------------------------------------------------
        DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh       
        DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh       
        DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh       
        DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh       
        DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh       
        DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh       
        DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh       
        DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh       
        DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh       
        DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        .DB   0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh





;----------------------------------------------------
;         Start of initialization - Z80 Test
;----------------------------------------------------
L0300:  XOR     A               ; A = 0
        OUT     (06Eh),A        ; Turn LED off
        OUT     (046h),A        ; Turn BEEP off
;----------------------------------------------------
;            Verify Stack Register
;----------------------------------------------------
        LD      SP,055AAh       ; Set Stack = 55AAh
        LD      HL,0AA56h       ; HL = AA56h
        ADD     HL,SP           ; Add together to get zero
        LD      A,H             ; Get result
        OR      L               ; Check if zero
L030E:  JR      NZ,L030E        ; Not zero, so don't continue

;----------------------------------------------------
;    Set all Registers to the same value and 
;    check register accuracy (BC,DE,HL).
;----------------------------------------------------
;            Verify Register ODD bits
;----------------------------------------------------
        LD      A,055h          ; A = 55h 
        LD      BC,05555h       ; B = 55h, C = 55h
        LD      DE,05555h       ; D = 55h, E = 55h
        LD      HL,05555h       ; H = 55h, L = 55h

        CP      B               ; Is B Register correct?
L031C:  JR      NZ,L031C        ; No, so don't continue
        CP      C               ; Is C Register correct?
L031F:  JR      NZ,L031F        ; No, so don't continue       
        CP      D               ; Is D Register correct?
L0322:  JR      NZ,L0322        ; No, so don't continue
        CP      E               ; Is E Register correct?
L0325:  JR      NZ,L0325        ; No, so don't continue
        CP      H               ; Is H Register correct?
L0328:  JR      NZ,L0328        ; No, so don't continue
        CP      L               ; Is L Register correct?
L032B:  JR      NZ,L032B        ; No, so don't continue

;----------------------------------------------------
;            Verify Register EVEN bits
;----------------------------------------------------
        LD      A,0AAh          ; A = AAh  Check EVEN bits
        LD      BC,0AAAAh       ; B = AAh, C = AAh
        LD      DE,0AAAAh       ; D = AAh, E = AAh
        LD      HL,0AAAAh       ; H = AAh, L = AAh

        CP      B               ; Is B Register correct?
L0339:  JR      NZ,L0339        ; No, so don't continue     
        CP      C               ; Is C Register correct?
L033C:  JR      NZ,L033C        ; No, so don't continue     
        CP      D               ; Is D Register correct?
L033F:  JR      NZ,L033F        ; No, so don't continue     
        CP      E               ; Is E Register correct?
L0342:  JR      NZ,L0342        ; No, so don't continue     
        CP      H               ; Is H Register correct?
L0345:  JR      NZ,L0345        ; No, so don't continue     
        CP      L               ; Is L Register correct?
L0348:  JR      NZ,L0348        ; No, so don't continue       

;----------------------------------------------------
;        Verify Prime Register ODD bits
;----------------------------------------------------
        EX      AF,AF'          ; Exchange Registers
        EXX                     ; Exchange Register
        LD      A,055h          ; A = 55h
        LD      BC,05555h       ; B = 55h, C = 55h
        LD      DE,05555h       ; D = 55h, E = 55h
        LD      HL,05555h       ; H = 55h, L = 55h

        CP      B               ; Is B Register correct?
L0358:  JR      NZ,L0358        ; No, so don't continue       
        CP      C               ; Is C Register correct?
L035B:  JR      NZ,L035B        ; No, so don't continue
        CP      D               ; Is D Register correct?
L035E:  JR      NZ,L035E        ; No, so don't continue
        CP      E               ; Is E Register correct?
L0361:  JR      NZ,L0361        ; No, so don't continue
        CP      H               ; Is H Register correct?
L0364:  JR      NZ,L0364        ; No, so don't continue
        CP      L               ; Is L Register correct?
L0367:  JR      NZ,L0367        ; No, so don't continue

;----------------------------------------------------
;        Verify Prime Register EVEN bits
;----------------------------------------------------
        LD      A,0AAh          ; A = AAh  Check EVEN bits
        LD      BC,0AAAAh       ; B = AAh, C = AAh
        LD      DE,0AAAAh       ; D = AAh, E = AAh
        LD      HL,0AAAAh       ; H = AAh, L = AAh

        CP      B               ; Is B Register correct?
L0375:  JR      NZ,L0375        ; No, so don't continue     
        CP      C               ; Is C Register correct?
L0378:  JR      NZ,L0378        ; No, so don't continue       
        CP      D               ; Is D Register correct?
L037B:  JR      NZ,L037B        ; No, so don't continue       
        CP      E               ; Is E Register correct?
L037E:  JR      NZ,L037E        ; No, so don't continue       
        CP      H               ; Is H Register correct?
L0381:  JR      NZ,L0381        ; No, so don't continue       
        CP      L               ; Is L Register correct?
L0384:  JR      NZ,L0384        ; No, so don't continue

;----------------------------------------------------
;         Verify IX, IY Index ODD bits
;----------------------------------------------------             
        LD      BC,05555h       ; B = 55h, C = 55h
        LD      IX,05555h       ; IX = 5555h
        LD      IY,05555h       ; IY = 5555h
        LD      DE,00397h       ; DE = Address of next test (EVEN Bits)
        JP      L0483           ; Jump to Z80 Register Test





;----------------------------------------------------
;         Verify IX, IY Index EVEN bits
;----------------------------------------------------
L0397:  LD      BC,0AAAAh       ; B = AAh, C = AAh
        LD      IX,0AAAAh       ; IX = AAAAh
        LD      IY,0AAAAh       ; IY = AAAAh
        LD      DE,003A8h       ; DE = Address of next test (LED/BEEP Test)
        JP      L0483           ; Jump to Z80 Register Test





;----------------------------------------------------
;                Go to Next Test
;----------------------------------------------------
L03A8:  LD      IX,003AFh       ; IX = Address of next test (ROM Verify)
        JP      L045B           ; Flash LED and BEEP, do next test





;----------------------------------------------------
;       Perform Diagnostic ROM Check
;----------------------------------------------------
L03AF:  LD      BC,00400h       ; BC = Start of COPYRIGHT pointers
        EXX                     ; EXX (Prime)
        LD      HL,L0000        ; HL' = 0
L03B6:  EXX                     ; EXX (Norm)
        LD      A,(BC)          ; Get first byte in table
        INC     BC              ; Point to next byte
        LD      E,A             ; E = LSB address byte
        LD      A,(BC)          ; Get next byte
        INC     BC              ; Point to next byte
        LD      D,A             ; D = MSB address byte
        OR      E               ; All Copyrights read?
        JR      Z,L040C         ; Yes, so jump ahead next test (Scratch RAM)

;----------------------------------------------------
;       DE = Pointer to Copyright Message
;----------------------------------------------------
        EXX                     ; EXX (Prime)
        LD      BC,02000h       ; BC' = Length of ROM 2K
        LD      A,(HL)          ; A = ROM byte
        LD      D,A             ; Save ROM byte temporarily D'
;----------------------------------------------------
;            HL = HL' (ROM location pointer)
;----------------------------------------------------
        LD      A,H             ; A   = H
        EXX                     ; EXX (Norm)
        LD      H,A             ; H = A = H'
        EXX                     ; EXX (Prime)
        LD      A,L             ; A = L' 
        EXX                     ; EXX (Norm)
        LD      L,A             ; L = A = L'
;----------------------------------------------------
        OR      A               ; Clear carry
        SBC     HL,DE           ; Subtract Copyright Address
        EXX                     ; EXX (Prime)
        LD      A,D             ; A = CHECKSUM byte
        JR      NZ,L03E9        ; Copyright reached, skip remaining bytes
        INC     HL              ; Point to next ROM byte
        DEC     BC              ; Decrement byte count loop
        LD      A,(HL)          ; A = CHECKSUM (First Byte)
        JR      L03E9           ; Jump ahead       
;----------------------------------------------------
;                    HL = HL'
;----------------------------------------------------
L03D9:  LD      D,A             ; Save CHECKSUM byte temporarily D'
        LD      A,H             ; A = H'
        EXX                     ; EXX (Norm)
        LD      H,A             ; H = A = H'
        EXX                     ; EXX (Prime)
        LD      A,L             ; A = L'
        EXX                     ; EXX (Norm)
        LD      L,A             ; L = A = L'
;----------------------------------------------------
        OR      A               ; Clear carry
        SBC     HL,DE           ; Check if we've reached Copyright Address
        EXX                     ; EXX (Prime)
        LD      A,D             ; Retreive CHECKSUM byte from D'
        JR      Z,L03E9         ; Copyright reached, skip remaining bytes
        XOR     (HL)            ; Exclusive OR CHECKSUM 
L03E9:  INC     HL              ; Point to next ROM byte
        DEC     C               ; Decrement byte count loop, C
        JR      NZ,L03D9        ; Loop not done so continue looping
        DJNZ    L03D9           ; Continue loop until all 2K bytes checked

        EXX                     ; EXX (Norm)
        EX      DE,HL           ; HL = DE
L03F1:  XOR     05Ah            ; Toggle Bits 01011010
        LD      (HL),A          ;
        CP      (HL)            ;
        JR      NZ,L03F1        ; Checksum incorrect, just loop               
        EX      DE,HL           ;
        EXX                     ; EXX (Prime)
        LD      IX,003B6h       ; IX = Address of next test (Next ROM)
        JP      L045B           ; Flash LED and BEEP, do next test





;----------------------------------------------------
;   Message Pointers "COPYRIGHT: STERN ELECTRONICS, INC."
;----------------------------------------------------
L0400:  .DW   012CDh   ; ROM0 Copyright Message location
        .DW   036E1h   ; ROM1 Copyright Message location 
        .DW   0582Ch   ; ROM2 Copyright Message location
        .DW   0660Eh   ; ROM3 Copyright Message location
        .DW   08927h   ; ROM4 Copyright Message location
        .DW   00000h   ; end 
   





;----------------------------------------------------
;              Scratch RAM Test
;----------------------------------------------------
L040C:  LD      HL,0E800h       ; HL = Start of Scratch RAM
        LD      DE,00800h       ; DE = Number of RAM bytes to test
        LD      IX,00419h       ; IX = Address of next test (BEEP)
        JP      L049B           ; Jump to RAM Test



;----------------------------------------------------
;     Flash LED and BEEP Begin Bookkeeping RAM Test
;----------------------------------------------------
L0419:  LD      IX,00420h       ; IX = Address of next test (Bookkeeping RAM)
        JP      L045B           ; Flash LED and BEEP, do next test





;----------------------------------------------------
;               Bookkeeping RAM Test
;----------------------------------------------------
;  Temporarily save Bookkeeping data while the 
;  RAM locations are being tested.
;----------------------------------------------------
L0420:  LD      HL,0E000h       ; HL = Source
        LD      DE,0E800h       ; DE = Destination
        LD      BC,00800h       ; BC = Number of bytes to copy
        LDIR                    ; Copy RAM locations

        LD      HL,0E000h       ; HL = Start of RAM
        LD      DE,00800h       ; DE = Number of RAM bytes to test
        LD      IX,00438h       ; IX = Address of next test (Restore RAM) 
        JP      L049B           ; Jump to RAM Test




;----------------------------------------------------
;    Restore Bookkeeping RAM back into its place
;----------------------------------------------------
L0438:  LD      HL,0E800h       ; HL = Source
        LD      DE,0E000h       ; DE = Destination
        LD      BC,00800h       ; BC = Number of bytes to copy
        LDIR                    ; Copy RAM locations
        LD      IX,L044A        ; IX = Address of next test (Video RAM)
        JP      L045B           ; Flash LED and BEEP, do next test



;----------------------------------------------------
;            Start Video RAM Test
;----------------------------------------------------
L044A:  LD      IX,L0451        ; IX = Address of next test (below)
        JP      L04C2           ; Jump to Video RAM Test



;----------------------------------------------------
;         Flash LED and BEEP, go to end of test
;----------------------------------------------------
L0451:  LD      IX,L0458        ; IX = Address to end of test
        JP      L045B           ; Flash LED and BEEP, do next test



;----------------------------------------------------
;               Testing Complete
;----------------------------------------------------
L0458:  JP      L000B           ; Testing complete, now return








;----------------------------------------------------
;       Flash LED and BEEP
;       IX = Address of next diagnostic test
;----------------------------------------------------
L045B:  OUT     (06Eh),A        ; Turn LED off
        XOR     A               ; A = 0
        OUT     (046h),A        ; Turn BEEP off
;----------------------------------------------------
;          Perform Delay = FFFFh
;----------------------------------------------------
        LD      BC,L0000        ; Setup delay value = FFFFh
L0463:  DEC     BC              ; Decrement delay
        LD      A,B             ; Get delay value
        OR      C               ; Check if delay finished
        JR      NZ,L0463        ; Delay not finished so continue loop       
;----------------------------------------------------
;             Turn on LED
;----------------------------------------------------
        OUT     (06Fh),A        ; Turn LED on
        LD      A,003h          ; A = 3
        OUT     (046h),A        ; Enable BEEP
;----------------------------------------------------
;          Perform Delay = 4000h
;----------------------------------------------------
        LD      BC,04000h       ; Setup delay value BC = 4000h
L0471:  DEC     BC              ; Decrement delay
        LD      A,B             ; Get delay value
        OR      C               ; Check if delay finished
        JR      NZ,L0471        ; Delay not finished so continue loop       
;----------------------------------------------------
;            Turn off LED
;----------------------------------------------------
        XOR     A               ; A = 0
        OUT     (046h),A        ; Turn BEEP OFF
;----------------------------------------------------
;          Perform Delay = C000h
;----------------------------------------------------
        LD      BC,0C000h       ; Setup delay value BC = C000h
L047C:  DEC     BC              ; Decrement delay
        LD      A,B             ; Get delay value
        OR      C               ; Check if delay finished
        JR      NZ,L047C        ; Delay not finished so continue loop       
;----------------------------------------------------
;       Test complete, jump to next test
;----------------------------------------------------
        JP      (IX)            ; Jump to next test








;----------------------------------------------------
;       Z80 Register Verification Test
;        BC = IX = IY = Test Value
;        DE = Address of next test
;----------------------------------------------------
L0483:  LD      HL,L0000        ; Clear HL Register for use
        LD      SP,IX           ; SP = IX Register
        ADD     HL,SP           ; Add zero to SP
        OR      A               ; Clear carry
        SBC     HL,BC           ; Test if BC equal IX
L048C:  JR      NZ,L048C        ; Register fault, so don't continue     
        LD      HL,L0000        ; Clear HL Register for use
        LD      SP,IY           ; SP = IY Register
        ADD     HL,SP           ; Add zero to SP
        OR      A               ; Cleary carry
        SBC     HL,BC           ; Test if BC equal IY
L0497:  JR      NZ,L0497        ; Register fault, so don't continue
        EX      DE,HL           ; Get Address of next test
        JP      (HL)            ; Jump to the next test








;----------------------------------------------------
;    RAM Test - Write then Read all RAM locations
;          HL = Start of RAM test
;          DE = Number of RAM bytes
;----------------------------------------------------
L049B:  XOR     A               ; A = 0
        SCF                     ; Set Carry Flag
L049D:  EX      AF,AF'          ; Save Test pattern AF
;----------------------------------------------------
;      Write Test Bit to (BC) RAM bytes
;----------------------------------------------------
        LD      B,D             ; Move Number of bytes into BC
        LD      C,E             ; ...BC = DE
L04A0:  EX      AF,AF'          ; Get Test Bit AF
        LD      (HL),A          ; Write Test Bit to RAM location
        INC     HL              ; Point to next RAM location
        RLA                     ; Shift Test Bit Left every time
        EX      AF,AF'          ; Save Test Bit AF
        DEC     BC              ; Decrement byte count (loop)
        LD      A,B             ; Check loop value
        OR      C               ; Are all bytes checked? (BC=0?)
        JR      NZ,L04A0        ; No, continue until all bytes written
               
;----------------------------------------------------
;      Read Test Bit from (BC) RAM bytes
;----------------------------------------------------
        LD      B,D             ; Move Number of bytes into BC
        LD      C,E             ; ...BC = DE                       
L04AC:  DEC     HL              ; Point to previous RAM location
        EX      AF,AF'          ; Get Test Bit AF
        RRA                     ; Shift Test Bit Right every time
        CP      (HL)            ; Is RAM location read correctly?
L04B0:  JR      NZ,L04B0        ; No, RAM is bad so don't continue
        OR      A               ; Has Test Bit rolled?
        JR      NZ,L04B6        ; No, so skip ahead       
        SCF                     ; Set Carry flag (Test Bit)
L04B6:  EX      AF,AF'          ; Save Test Bit AF
        DEC     BC              ; Decrement byte count loop
        LD      A,B             ; Check Loop Value
        OR      C               ; Are all bytes checked?
        JR      NZ,L04AC        ; No, so continue looping
             
;----------------------------------------------------
;      Move to next bit and repeat RAM Test
;----------------------------------------------------               
        EX      AF,AF'          ; Get Test Bit
        RLA                     ; Shift Test Bit Left
        JR      NC,L049D        ; Loop back until all bits tested
        JP      (IX)            ; Jump to next test







;----------------------------------------------------
;               Video RAM Test 1K
;----------------------------------------------------
L04C2:  XOR     A               ; A = 0
        LD      (0E115h),A      ; Clear Graphics Chip Write Request
        LD      SP,0F000h       ; Setup Stack Pointer
        LD      A,046h          ; Text = DK_BLUE, Bkgnd = DK_RED
        CALL    L20CA           ; Setup Graphics Chip for Text
        LD      HL,000FFh       ;
        LD      DE,055AAh       ;
        LD      B,008h          ;
L04D6:  PUSH    BC              ; Save BC Register
        PUSH    HL              ; Save HL Register 
        PUSH    DE              ; Save DE Register
        LD      HL,00000h       ; Cursor Position (X=0,Y=0)
        CALL    L2334           ; Set Text Cursor Position
        POP     DE              ; Restore DE Register
        POP     HL              ; Restore HL Register           
        LD      BC,01000h       ; BC = Loop 1K of RAM
L04E4:  LD      A,H             ;
        OUT     (044h),A        ;
        PUSH    AF              ;
        POP     AF              ;
        LD      A,L             ;
        OUT     (044h),A        ;
        PUSH    AF              ; 
        POP     AF              ;
        LD      A,D             ;
        OUT     (044h),A        ;
        PUSH    AF              ;
        POP     AF              ;
        LD      A,E             ;
        OUT     (044h),A        ;
        PUSH    AF              ;
        POP     AF              ;
        DEC     BC              ;
        LD      A,B             ;
        OR      C               ;
        JR      NZ,L04E4        ;       

        PUSH    HL              ; Save HL Register
        PUSH    DE              ; Save DE Register
        LD      HL,L0000        ; Cursor Position (X=0,Y=0)
        CALL    L2343           ; Set Text Cursor Position
        POP     DE              ; Restore DE Register
        POP     HL              ; Restore HL Register 

        LD      BC,01000h       ; BC = Loop 1K RAM
L050A:  PUSH    AF              ;
        POP     AF              ;
        IN      A,(045h)        ;
        CP      H               ;
L050F:  JR      NZ,L050F        ;       
        PUSH    AF              ;
        POP     AF              ;
        IN      A,(045h)        ;
        CP      L               ;
L0516:  JR      NZ,L0516        ;       
        PUSH    AF
        POP     AF
        IN      A,(045h)
        CP      D
L051D:  JR      NZ,L051D               
        PUSH    AF
        POP     AF
        IN      A,(045h)
        CP      E
L0524:  JR      NZ,L0524               
        DEC     BC
        LD      A,B
        OR      C
        JR      NZ,L050A               
        LD      A,H             ;
        LD      H,L             ;
        LD      L,D             ;
        LD      D,E             ;
        LD      E,A             ;
        POP     BC              ;
        DJNZ    L04D6           ;       
        JP      (IX)            ;








;----------------------------------------------------
;               Power Up LDPlayer
;----------------------------------------------------
L0535:  LD      A,01Ah          ; Command = POWER_UP
        CALL    L2085           ; Issue Command to LDPlayer
        JP      L0604           ; Begin Game







;----------------------------------------------------
;             Copy 'Generic' High Scores
;----------------------------------------------------
L053D:  LD      HL,01112h       ; Pointer to Generic High Scores
        LD      DE,0E050h       ; Pointer to High Score locations
        LD      BC,00050h       ; BC = 80 (10 high scores * 8)
        LDIR                    ; Copy in Generic High Scores
;----------------------------------------------------
;            Setup Graphics Chip Registers
;----------------------------------------------------
        LD      SP,0F000h       ; Stack Pointer = F000h
        LD      IX,0E12Fh       ; Graphics Registers E12F -E136
        LD      (IX+000h),000h  ;
        LD      (IX+001h),0B0h  ; Mode 1
        LD      (IX+002h),000h  ;
        LD      (IX+003h),000h  ;
        LD      (IX+004h),000h  ;
        LD      (IX+005h),000h  ;
        LD      (IX+006h),000h  ;
        LD      (IX+007h),000h  ;
        CALL    L2316           ; Write Graphics Registers
        CALL    L2392           ;
        CALL    L22F5           ; Program Graphics Chip
        CALL    GoodBeep        ; Sound Good Beep
        LD      A,0F1h          ; Text = WHITE, Bkgnd = BLACK
        CALL    L20CA           ; Setup Graphics Chip for Text         
        CALL    L21FF           ; Clear Text Display
        PUSH    HL              ; Save HL Register
        LD      HL,001EDh       ; Cursor Position
        CALL    L2212           ; Set Cursor and Print Text
;----------------------------------------------------
        .TEXT   "PLEASE STANDBY"
        .DB   000h 
;----------------------------------------------------
        POP     HL              ; Restore HL Register
        LD      A,(0E18Ch)      ; Get DIP Switches 12-19
        BIT     0,A             ; Check if Service Mode enabled
        JP      NZ,L40FE        ; Enabled so perform Service Mode
        BIT     1,A             ; Check for Switch Test 
        JP      NZ,L3720        ; Enabled so perform Switch Test
;----------------------------------------------------
;            Start up LDPlayer
;   Send Play Command 45 times, if no frames are
;   being detected after a set time then ERROR.
;----------------------------------------------------
L05A7:  LD      E,02Dh          ; E = Loop Retry 45 times

L05A9:  LD      A,005h          ; Command = PLAY (05h)
        CALL    L207F           ; Send Message to LDPlayer DI

        LD      A,(0E126h)      ; Get Control Register
        RES     4,A             ; Clear PAUSE bit
        LD      (0E126h),A      ; Save Control Register

        CALL    L242F           ; Delay 1,000

        LD      A,(0E126h)      ; Get Control Register
        SET     1,A             ; Set Frame Count Wait bit
        LD      (0E126h),A      ; Save Control Register

        LD      BC,0E000h       ; BC = Timeout Value for LDPlayer
        LD      HL,0E112h       ; Get FrameCount Pulse
L05C7:  LD      A,(HL)          ; Read FrameCount Pulse
        CP      (HL)            ; Check if Frame Count Input arrived
        JR      NZ,L05FE        ; Input has arrived so skip ahead       
        DEC     BC              ; Decrement Timeout Timer
        LD      A,B             ; Check Timeout Timer
        OR      C               ; Has Timeout expired?
        JR      NZ,L05C7        ; No so continue waiting
        DEC     E               ; Decrement retry count
        JR      NZ,L05A9        ; Retry 45 times so loop back       

        PUSH    HL              ; Save HL Register
        LD      HL,001E7h       ; Cursor Position
        CALL    L2212           ; Set Cursor and Print Text
;----------------------------------------------------
L05DA:  .TEXT  "** DISC NOT UP TO SPEED **"
        .DB    000h
;----------------------------------------------------       
        POP     HL              ; Restore HL Register
        CALL    BadBeep         ; Sound Bad Beep
        CALL    Delay500000     ; Call Delay for 500,000
        JR      L05A7           ; Keep trying to play disc       


;----------------------------------------------------
;               LDPlayer Started
;----------------------------------------------------
L05FE:  CALL    GoodBeep        ; Sound Good Beep
        CALL    L21FF           ; Clear Text Display         

L0604:  LD      A,(0E126h)      ; Get Control Register
        BIT     1,A             ; Is LDPlayer Busy?
        JR      NZ,L0604        ; Yes, so wait here

        LD      A,(0E126h)      ; Get Control Register
        BIT     4,A             ; Check if LDPlayer is PAUSED
        JR      NZ,L061F        ; Already PAUSED so skip over next part 
;----------------------------------------------------
;             Send PAUSE Command
;----------------------------------------------------
        LD      A,00Ah          ; Command = PAUSE (0Ah)
        CALL    L207F           ; Send Message to LDPlayer DI
        LD      A,(0E126h)      ; Get Control Register
        SET     4,A             ; Set PAUSE Bit
        LD      (0E126h),A      ; Save Control Register

L061F:  CALL    L1627           ; Reset Bookkeeping Data
;----------------------------------------------------
;     Check DIP switches for:
;     Service Mode, Switch Test, and Disc Diagnostic
;----------------------------------------------------
        LD      A,(0E18Ch)      ; Get DIP Switches 12-19
        BIT     0,A             ; Check Service Mode
        JP      NZ,L40FE        ; Enabled, so perform Service Mode
        BIT     1,A             ; Check Switch Test
        JP      NZ,L3720        ; Enabled, so perform Switch Test
        BIT     4,A             ; Check Disc Test
L0631:  JP      NZ,L6770        ; Enabled, so perform LaserDisc Diagnostics
        LD      A,(0E18Ch)      ; Get DIP Switches 12-19
        BIT     5,A             ; Check Attract Mode Sound
        JR      Z,L067F         ; Disabled, so skip Audio Setup

;----------------------------------------------------
;                  Audio Setup
;----------------------------------------------------               
L063B:  LD      A,(0E126h)      ; Get Control Register
L063E:  BIT     1,A             ;
L0640:  JR      NZ,L063B        ; 
;----------------------------------------------------
;                Handle LEFT_AUDIO
;----------------------------------------------------     
L0642:  LD      A,(0E126h)      ; Get Control Register
        BIT     1,A             ;
        JR      NZ,L0642        ;       

        LD      A,(0E126h)      ; Get Control Register
        BIT     6,A             ; Is LEFT_AUDIO already ON?
        JR      Z,L065D         ; Yes, so skip to right audio       

        LD      A,00Eh          ; Command = LEFT_AUDIO (0Eh) 
        CALL    L207F           ; Send Message to LDPlayer DI

        LD      A,(0E126h)      ; Get Control Register
        RES     6,A             ; Set Audio Left ON
        LD      (0E126h),A      ; Save Control Register

L065D:  PUSH    AF              ; Save AF Register
        LD      A,000h          ; Command = <unknown> (00h)
        CALL    L2085           ; Issue Command to LDPlayer
        POP     AF              ; Restore AF Register
;----------------------------------------------------
;              Handle RIGHT_AUDIO
;----------------------------------------------------
L0664:  LD      A,(0E126h)      ; Get Control Register
        BIT     1,A             ;
        JR      NZ,L0664        ;       

        LD      A,(0E126h)      ; Get Control Register
        BIT     5,A             ;
        JR      Z,L067F         ;       
        LD      A,00Dh          ; Command = RIGHT_AUDIO (0Dh)
        CALL    L207F           ; Send Message to LDPlayer DI
        LD      A,(0E126h)      ; Get Control Register
        RES     5,A             ;
        LD      (0E126h),A      ; Save Control Register


L067F:  LD      A,(0E126h)      ; Get Control Register
        RES     3,A             ;
        LD      (0E126h),A      ; Save Control Register

L0687:  LD      A,(0E126h)      ; Get Control Register
        BIT     1,A             ;
        JR      NZ,L0687        ;       

        LD      A,(0E126h)      ; Get Control Register
        BIT     4,A             ; Check PAUSE bit
        JR      Z,L06A2         ; LDPlayer already paused so skip ahead       
;----------------------------------------------------
;               Send PAUSE Command
;----------------------------------------------------
        LD      A,00Ah          ; Command = PAUSE (0Ah)
        CALL    L207F           ; Send Message to LDPlayer DI
        LD      A,(0E126h)      ; Get Control Register
        RES     4,A
        LD      (0E126h),A      ; Save Control Register
;----------------------------------------------------
;              Show CLIFF HANGER Intro
;----------------------------------------------------
L06A2:  CALL    DoIntroScreen   ; Show "CLIFF HANGER" Graphics
        CALL    Delay500000     ; Call Delay 500,000
        LD      IX,03704h       ;
        LD      IY,03704h       ;
        JP      L088B           ;

L06B3:  LD      A,(0E126h)      ; Get Control Register
        BIT     1,A             ;
        JR      NZ,L06B3        ;       
        LD      A,(0E126h)      ; Get Control Register
        BIT     4,A             ;
        JR      NZ,L06CE        ;       
;----------------------------------------------------
;             Send PAUSE Command
;----------------------------------------------------
        LD      A,00Ah          ; Command = PAUSE (0Ah)
        CALL    L207F           ; Send Message to LDPlayer DI
        LD      A,(0E126h)      ; Get Control Register
        SET     4,A             ; Set PAUSE Bit
        LD      (0E126h),A      ; Save Control Register
L06CE:  LD      A,(0E126h)      ; Get Control Register
        SET     0,A             ; 
        LD      (0E126h),A      ; Save Control Register
L06D6:  LD      A,(0E126h)      ; Get Control Register
        BIT     1,A             ;
        JR      NZ,L06D6        ;       
        LD      A,(0E126h)      ; Get Control Register
        BIT     4,A             ;
        JR      NZ,L06F1        ;       
;----------------------------------------------------
;             Send PAUSE Command
;----------------------------------------------------
        LD      A,00Ah          ; Command = PAUSE (0Ah)
        CALL    L207F           ; Send Message to LDPlayer DI
        LD      A,(0E126h)      ; Get Control Register
        SET     4,A             ; Set PAUSE Bit
        LD      (0E126h),A      ; Save Control Register

L06F1:  CALL    L53BB           ; Show Score or Programmer's Names
        CALL    Delay500000     ; Call Delay 500,000
        CALL    L1CF8           ; Show High Scores
        CALL    Delay500000     ; Call Delay 500,000
        CALL    L168D           ; Check if user needs Instructions
        CALL    Delay500000     ; Call Delay 500,000
        CALL    Delay500000     ; Call Delay 500,000
        JP      L067F           ;








;----------------------------------------------------
;           Increment Scene Pointers
;----------------------------------------------------
L0709:  LD      HL,(0E1BBh)     ; Get Scene Pointer
        INC     HL              ; Increment Scene Pointer
        INC     HL              ; Increment Scene Pointer
        LD      A,(0E1B6h)      ; Get Current Scene
        INC     A               ; Go to next scene
        CP      009h            ; Have we played all 9 scenes?                 
        JR      C,L0760         ; No, so skip ahead       
;----------------------------------------------------
;            Final Scene has been completed
;----------------------------------------------------
        LD      A,000h          ; A = 0
        LD      (0E1AEh),A      ; Clear Lives Remaining
        LD      (0E1B6h),A      ; Reset Current Scene Number
        LD      (0E1BBh),A      ; Clear Scene Pointer
        LD      (0E1BCh),A      ; Clear Scene Pointer
        CALL    L3C3A           ; Do Congratulation Celebration
        JP      L1EA2           ; Swap players







;----------------------------------------------------
;
;----------------------------------------------------
L072A:  LD      A,(0E126h)      ; Get Control Register
        RES     0,A             ;
        LD      (0E126h),A      ; Save Control Register

        LD      A,(0E186h)      ; Get DIP Switches 28-35 
        BIT     3,A             ; Check ? (sw 30)
        JR      NZ,L074F        ; Don't Play, so skip ahead
               
        LD      A,(0E111h)      ;
        AND     007h            ;
        RLCA                    ;
        LD      (0E15Dh),A      ;
        LD      E,A             ;
        LD      D,000h          ;
        LD      HL,007CBh       ; HL = 
        ADD     HL,DE           ;
        LD      E,(HL)
        INC     HL
        LD      D,(HL)
        EX      DE,HL
        JR      L075E                   

L074F:  LD      A,(0E18Ch)      ; Get DIP Switches 12-19
        BIT     6,A             ; Check SHORT/LONG Scenes
        JR      NZ,L075B        ; Set so use LONG Scenes       
        LD      HL,007BBh       ; Initial Scene Pointer (SHORT)
        JR      L075E           ; Skip LONG
                           
L075B:  LD      HL,007ABh       ; Initial Scene Pointer (LONG)

L075E:  LD      A,001h          ; Set Current Scene to 1
L0760:  LD      (0E1B6h),A      ; Save Current Scene
        LD      (0E1BBh),HL     ; Save Scene Pointer
        LD      E,(HL)          ; DE = First Scene Location
        INC     HL              ; Next spot
        LD      D,(HL)          ; DE = First Scene Location
        PUSH    DE              ; Save First Scene Location
        POP     IX              ; IX = First Scene Location
        PUSH    DE              ; Save First Scene Location
        POP     IY              ; IY = First Scene Location
        JP      L085B           ; Game Mechanics





;----------------------------------------------------
;            Do Player Game
;----------------------------------------------------
L0772:  LD      A,(0E1B6h)      ;
        OR      A               ;
        JR      Z,L072A         ;       
        LD      IX,(0E1AFh)     ;
        LD      IY,(0E1B1h)     ;
        LD      BC,(0E1B3h)     ;
        LD      A,B             ;
        OR      A               ;
        JR      Z,L0709         ; Increment pointers to next scene       
        LD      DE,0000Fh       ;
        ADD     IY,DE           ;
        LD      B,(IY+000h)     ;
        LD      E,(IY+001h)     ;
        LD      D,(IY+002h)     ;
        PUSH    DE              ;
        POP     IY              ; IY = Next scene address
        INC     IY              ;
        INC     IY              ;
        INC     IY              ;
        CALL    L095A           ; Play Death Scene for Incorrect Move
        DEC     IY              ;
        DEC     IY              ;
        DEC     IY              ;
        JP      L0878           ;
                               


;----------------------------------------------------
;               Scene Data Pointers
;----------------------------------------------------
L07AB:      .DW   02629h     ; Scene 1 - longest scenes       
            .DW   0270Eh     ; Scene 2     
            .DW   02925h     ; Scene 3       
            .DW   02BBAh     ; Scene 4       
            .DW   02F5Dh     ; Scene 5       
            .DW   03030h     ; Scene 6   
            .DW   03115h     ; Scene 7       
            .DW   03350h     ; Scene 8       


L07BB:      .DW   05C4Fh     ; Scene 1 - longer scenes         
            .DW   05D34h     ; Scene 2       
            .DW   02925h     ; Scene 3         
            .DW   05F4Bh     ; Scene 4     
            .DW   02F5Dh     ; Scene 5       
            .DW   062EEh     ; Scene 6         
            .DB   063D3h     ; Scene 7         
            .DB   03350h     ; Scene 8
           
;----------------------------------------------------
;               Scene Data Indexes
;----------------------------------------------------
L07CB:      .DW   007DBh             
            .DW   007EBh             
            .DW   007FBh             
            .DW   0080Bh 
            .DW   0081Bh 
            .DW   0082Bh 
            .DW   0083Bh             
            .DW   0084Bh 
           

;----------------------------------------------------
;           Scene Data Pointers (cont)
;----------------------------------------------------
L07DB:      .DW   07DB8h     ; Scene 1 
            .DW   07E1Fh     ; Scene 2     
            .DW   08000h     ; Scene 3       
            .DW   0824Dh     ; Scene 4       
            .DW   02F5Dh     ; Scene 5       
            .DW   062EEh     ; Scene 6   
            .DW   063D3h     ; Scene 7       
            .DW   085DEh     ; Scene 8       
                       
L07EB:      .DW   05C4Fh     ; Scene 1         
            .DW   07E1Fh     ; Scene 2         
            .DW   08000h     ; Scene 3         
            .DW   0824Dh     ; Scene 4         
            .DW   02F5Dh     ; Scene 5         
            .DW   062EEh     ; Scene 6         
            .DW   063D3h     ; Scene 7         
            .DW   085DEh     ; Scene 8 
             
L07FB:      .DW   07DB8h     ; Scene 1         
            .DW   05D34h     ; Scene 2         
            .DW   08000h     ; Scene 3       
            .DW   0824Dh     ; Scene 4         
            .DW   02F5Dh     ; Scene 5         
            .DW   062EEh     ; Scene 6         
            .DW   063D3h     ; Scene 7         
            .DW   085DEh     ; Scene 8 
             
L080B:      .DW   07DB8h     ; Scene 1 - short scenes         
            .DW   07E1Fh     ; Scene 2 
            .DW   02925h     ; Scene 3 
            .DW   0824Dh     ; Scene 4         
            .DW   02F5Dh     ; Scene 5         
            .DW   062EEh     ; Scene 6         
            .DW   063D3h     ; Scene 7     
            .DW   085DEh     ; Scene 8 
             
L081B:      .DW   07DB8h     ; Scene 1         
            .DW   07E1Fh     ; Scene 2         
            .DW   08000h     ; Scene 3         
            .DW   05F4Bh     ; Scene 4         
            .DW   02F5Dh     ; Scene 5         
            .DW   062EEh     ; Scene 6         
            .DW   063D3h     ; Scene 7         
            .DW   085DEh     ; Scene 8         

L082B:      .DW   07DB8h             
            .DB  1Fh 
            .DB  7Eh 
            .DB    0 
            .DB  80h 
            .DB  4Dh 
            .DB  82h 
            .DB  5Dh 
            .DB  2Fh 
            .DB 0EEh 
            .DB  62h 
            .DB 0D3h 
            .DB  63h 
            .DB 0DEh 
            .DB  85h 
            .DB 0B8h 
            .DB  7Dh 
            .DB  1Fh 
            .DB  7Eh 
            .DB    0 
            .DB  80h 
            .DB  4Dh 
            .DB  82h 
            .DB  5Dh 
            .DB  2Fh 
            .DB 0EEh 
            .DB  62h 
            .DB 0D3h 
            .DB  63h 
            .DB 0DEh 
            .DB  85h 
            .DB 0B8h 
            .DB  7Dh 
            .DB  1Fh 
            .DB  7Eh 
            .DB    0 
            .DB  80h 
            .DB  4Dh 
            .DB  82h 
            .DB  5Dh 
            .DB  2Fh 
            .DB 0EEh 
            .DB  62h 
            .DB 0D3h 
            .DB  63h 
            .DB 0DEh 
            .DB  85h 








;----------------------------------------------------
;              Scene Mechanics
;----------------------------------------------------
;       IY = First Scene Location (example 2629h)
;       IX = First Scene Location
;----------------------------------------------------
L085B:  CALL    L095A           ; Play Death Scene for Incorrect Move
        CALL    L08F4           ;

        LD      A,(IX+00Ch)     ; A = Number of Joystick Moves
        CP      000h            ; Are there any moves?
        JR      Z,L088B         ; No, so skip ahead

        LD      B,A             ; Loop = Number of Moves
        DEC     IY              ;
        DEC     IY              ;
        DEC     IY              ;
        DEC     IY              ;
        DEC     IY              ;

L0873:  LD      DE,00012h       ; 18 bytes per move
        ADD     IY,DE           ; Index to next move
L0878:  LD      (0E1B3h),BC     ; Save Move Address (loop)
        CALL    L0AED           ;
        CALL    L0DEB           ; Show Stick and Action Hints
        CALL    L0B79           ;
        LD      BC,(0E1B3h)     ; Restore Loop
        DJNZ    L0873           ; Loop until finished       

L088B:  LD      A,000h          ; A = 0
        LD      (0E122h),A      ; Clear number of errors
        LD      DE,00003h       ; 
        ADD     IX,DE           ;
        CALL    L0DAF           ; Wait until frame number reached
        LD      A,(0E126h)      ; Get Control Register
        BIT     0,A             ;
        JP      NZ,L06B3        ;
;----------------------------------------------------
;      Scene Bonus:  Award 10,000 Points to Score
;----------------------------------------------------
        XOR     A               ; A = 0
        LD      (0E127h),A      ; Bonus 10000000/1000000 = 0
        LD      (0E129h),A      ; Bonus 1000/100 = 0
        LD      (0E12Ah),A      ; Bonus 10/1     = 0
        LD      A,001h          ; Set 10,000 Points
        LD      (0E128h),A      ; Bonus 100000/10000 = 01
        CALL    L0F8F           ; Award Points and Update Score Display
        JP      L0709           ; Increment pointers to next scene








;----------------------------------------------------
;            Search to Frame Number
;----------------------------------------------------
;      (IY+00) thru (IY+02) = Frame Number
;---------------------------------------------------- 
L08B5:  LD      A,(0E126h)      ; Get Control Register
        BIT     1,A             ;
        JR      NZ,L08B5        ; Wait until ?               
        DI                      ; Disable Interrupts
        LD      A,00Bh          ; Command = SEARCH (0Bh)
        CALL    L2085           ; Issue Command to LDPlayer

        LD      A,(0E126h)      ; Get Control Register
        RES     4,A             ; Clear PAUSE bit
        LD      (0E126h),A      ; Save Control Register

        CALL    L09CC           ; Send FRAME NUMBER to LDPlayer
        LD      A,00Bh          ; Command = SEARCH (0Bh)
        CALL    L2085           ; Issue Command to LDPlayer

        LD      A,(0E126h)      ; Get Control Register
        RES     4,A             ; Clear PAUSE bit
        LD      (0E126h),A      ; Save Control Register

        LD      A,(IY+000h)     ;
        LD      (0E119h),A      ;
        LD      A,(IY+001h)     ;
        LD      (0E11Ah),A      ;
        LD      A,(IY+002h)     ;
        LD      (0E11Bh),A      ;
        CALL    Delay100000     ; Call Delay 100,000
        CALL    L20B4           ;
        EI                      ; Enable Interrupts
        RET                     ; Return







;----------------------------------------------------
;                   Set Audio
;----------------------------------------------------
SetAudio:
L08F4:  LD      A,(0E126h)      ; Get Control Register 
        BIT     0,A             ;
        RET     NZ              ;
L08FA:  LD      A,(0E126h)      ; Get Control Register
        BIT     1,A             ;
        JR      NZ,L08FA        ;       
L0901:  LD      A,(0E126h)      ; Get Control Register
        BIT     1,A             ;
        JR      NZ,L0901        ;       
        LD      A,(0E126h)      ; Get Control Register
        BIT     4,A             ;
        JR      Z,L091C         ;       
        LD      A,00Ah          ; Command = PAUSE (0Ah)
        CALL    L207F           ; Send Message to LDPlayer DI
        LD      A,(0E126h)      ; Get Control Register
        RES     4,A
        LD      (0E126h),A      ; Save Control Register
;----------------------------------------------------
;                Handle LEFT_AUDIO
;----------------------------------------------------
L091C:  LD      A,(0E126h)      ; Get Control Register
        BIT     1,A             ;
        JR      NZ,L091C        ;       
        LD      A,(0E126h)      ; Get Control Register
        BIT     6,A             ; Is LEFT_AUDIO already ON?
        JR      NZ,L0937        ; Yes, so skip to right audio

        LD      A,00Eh          ; Command = LEFT_AUDIO (0Eh)
        CALL    L207F           ; Send Message to LDPlayer DI
        LD      A,(0E126h)      ; Get Control Register
        SET     6,A             ; Set LEFT_AUDIO ON
        LD      (0E126h),A      ; Save Control Register
;----------------------------------------------------
;                Handle RIGHT_AUDIO
;----------------------------------------------------
L0937:  LD      A,(0E126h)      ; Get Control Register
        BIT     1,A             ;
        JR      NZ,L0937        ;       
        LD      A,(0E126h)      ; Get Control Register
        BIT     5,A             ; Is RIGHT_AUDIO already ON?
        JR      NZ,L0952        ; Yes, so skip ahead

        LD      A,00Dh          ; Command = RIGHT_AUDIO (0Dh)
        CALL    L207F           ; Send Message to LDPlayer DI
        LD      A,(0E126h)      ; Get Control Register
        SET     5,A             ; Set RIGHT_AUDIO ON
        LD      (0E126h),A      ; Save Control Register

L0952:  PUSH    AF              ; Save AF Register
        LD      A,000h          ; Command = TOGGLE
        CALL    L2085           ; Issue Command to LDPlayer
        POP     AF              ; Restore AF Register
        RET                     ; Return









;----------------------------------------------------
;          Play Death Scene for Incorrect Move
;----------------------------------------------------
;       IY = Scene Location
;       IX = First Scene Location
;----------------------------------------------------
L095A:  PUSH    BC              ; Save BC Register
        CALL    L53BB           ; Show Score or Programmer's Name
        LD      A,(IY+001h)     ;
        OR      A               ;
        JR      NZ,L0978        ;       

        PUSH    DE              ; Save DE Register
        LD      DE,00012h       ; Index to next move (18 bytes)
        LD      IY,(0E1B1h)     ; Get frame Number
        ADD     IY,DE           ; Add Index
        LD      (0E1B1h),IY     ;
        LD      DE,00009h       ;
        ADD     IY,DE           ; IY = Frame Address
        POP     DE              ; Restore DE Register

L0978:  CALL    L08B5           ; Search to Frame Number
        XOR     A               ; A = 0
        LD      (0E15Bh),A      ; Reset 
        CALL    L0A8B           ; ChkSearch
        CALL    L53A9           ; Clear Overlay?
;----------------------------------------------------
;                 Send PLAY Command
;----------------------------------------------------
L0985:  LD      A,005h          ; Command = PLAY (05h)
        CALL    L207F           ; Send Message to LDPlayer DI

        LD      A,(0E126h)      ; Get Control Register
        RES     4,A             ; Clear PAUSE bit
        LD      (0E126h),A      ; Save Control Register

        LD      A,(0E118h)      ; Get Frame Count
        LD      B,A             ; Save Frame Count
        CALL    L2353           ; Wait for Comm Ready
        CALL    L2353           ; Wait for Comm Ready
        CALL    L2353           ; Wait for Comm Ready
        LD      A,(0E118h)      ; Get Frame Count
        CP      B               ; Compare to previous frame count
        JR      NZ,L09AE        ; Frame has changed so skip ahead
               
        LD      A,(0E15Eh)      ; Get Crazy Counter
        INC     A               ; Increment Crazy Counter
        LD      (0E15Eh),A      ; Save Crazy Counter
        JR      L0985           ; Go back and try again

L09AE:  CALL    L21FF           ; Clear Text Display
        LD      A,(0E126h)      ; Get Control Register
        BIT     2,A             ;
        JP      NZ,L09CA        ;

;----------------------------------------------------
;         Print Player1 or Player2 Score
;----------------------------------------------------
        LD      A,(0E1A9h)      ; Get Player Number
        CP      001h            ; Is it Player1?
        LD      A,060h          ; Player1, Text = DK RED, Bkgnd = TRANS
        JR      Z,L09C4         ; Skip ahead       
        LD      A,040h          ; Player2, Text = BLUE, Bkgnd = TRANS
L09C4:  CALL    L2111           ; Set Text Color
        CALL    L0EB9           ; Overlay Score

L09CA:  POP     BC              ; Restore BC Register
        RET                     ; Return









;----------------------------------------------------
;      Send Frame Number to LDPlayer
;      (IY+00) thru (IY+02) = Frame Number
;----------------------------------------------------
L09CC:  PUSH    IX              ; Save IX Register
        PUSH    IY              ; Save IY Register
        PUSH    BC              ; Save BC Register
        LD      IX,0E10Eh       ; IX = ?
        LD      (IX+000h),000h  ;
        LD      A,(IY+000h)     ; Get Ten Thousanths digit 
        AND     00Fh            ; Isolate digit
        CALL    L0A13           ; Send Digit to LDPlayer
        LD      A,(IY+001h)     ;
        SRL     A               ;
        SRL     A               ;
        SRL     A               ;
        SRL     A               ;
        CALL    L0A13           ; Send Digit to LDPlayer
        LD      A,(IY+001h)     ;
        AND     00Fh            ;
        CALL    L0A13           ; Send Digit to LDPlayer
        LD      A,(IY+002h)     ;
        SRL     A               ;
        SRL     A               ;
        SRL     A               ;
        SRL     A               ;
        CALL    L0A13           ; Send Digit to LDPlayer
        LD      A,(IY+002h)     ;
        AND     00Fh            ; Isolate Digit
        CALL    L0A13           ; Send Digit to LDPlayer
        POP     BC              ; Restore BC Register
        POP     IY              ; Restore IY Register
        POP     IX              ; Restore IX Register
        RET                     ; Return







;----------------------------------------------------
;   Get Command Byte from Table and send to LDPlayer
;        A  = Digit to Send
;        IX = ?
;----------------------------------------------------
L0A13:  LD      HL,L20AA        ; Load start of Command Table Digits
        LD      D,000h          ; D = 0
        LD      E,A             ; DE = Index
        ADD     HL,DE           ; Add index to start of Command Table Digits
        LD      A,(HL)          ; Get Command Byte (digit)
        CP      (IX+000h)       ;
        LD      (IX+000h),A     ;
        JR      NZ,L0A2A        ;       
        PUSH    AF              ; Save AF Register
        LD      A,000h          ; Command = blank (?)
        CALL    L2085           ; Issue Command to LDPlayer
        POP     AF              ; Restore AF Register
L0A2A:  CALL    L2085           ; Issue Command to LDPlayer
        RET                     ; Return







;----------------------------------------------------
;      Check if certain Frame Number was reached
;        IY = Address of Target frame
;----------------------------------------------------
L0A2E:  POP     HL              ; Restore HL Register
        POP     DE              ; Restore DE Register
        POP     BC              ; Restore BC Register
        POP     IY              ; Restore IY Register
L0A33:  PUSH    IY              ; Save IY Register
        PUSH    BC              ; Save BC Register
        PUSH    DE              ; Save DE Register
        PUSH    HL              ; Save HL Register
;----------------------------------------------------
;             Get Target Frame Number
;----------------------------------------------------
        XOR     A               ; A = 0 
        LD      (0E127h),A      ; Erase Temp Subtract locations
        LD      (0E17Fh),A      ; Erase Frame Subtract locations
        LD      A,(IY+000h)     ; Get Target frame number
        LD      (0E180h),A      ; Save Target frame number
        LD      A,(IY+001h)     ; Get Target frame number
        LD      (0E181h),A      ; Save Target frame number
        LD      A,(IY+002h)     ; Get Target frame number
        LD      (0E182h),A      ; Save Target frame number

;----------------------------------------------------
;        Wait for frame data from LDPlayer
;----------------------------------------------------
        PUSH    HL              ; Save HL Register
        LD      HL,0E112h       ; HL = LDPlayer Pulse
        LD      A,(HL)          ; Get LDPlayer Pulse
L0A56:  CP      (HL)            ; Check if any data received
        JR      Z,L0A56         ; Wait here for frame data

;----------------------------------------------------
;             Get Current Frame Number
;----------------------------------------------------
        POP     HL              ; Restore HL Register
        LD      A,(0E116h)      ; Get Current Frame Number
        LD      (0E128h),A      ; Save Current Frame Number
        LD      A,(0E117h)      ; Get Current Frame Number
        LD      (0E129h),A      ; Save Current Frame Number
        LD      A,(0E118h)      ; Get Current Frame Number
        LD      (0E12Ah),A      ; Save Current Frame Number

;----------------------------------------------------
;       Compare frame data with target frame
;----------------------------------------------------
        LD      DE,0E182h       ; Setup Subtract pointer
        CALL    L0FCC           ; Call 3-Digit Subtraction
        JR      C,L0A80         ; Frame number reached so leave       
        LD      HL,(0E181h)     ;
        LD      A,(0E180h)      ;
        OR      H               ;
        OR      L               ;
        JR      Z,L0A80         ; Error abort search       
        JR      L0A2E           ; Loop until frame number is reached       

L0A80:  POP     HL              ; Restore HL Register
        POP     DE              ; Restore DE Register
        POP     BC              ; Restore BC Register
        POP     IY              ; Restore IY Register
        RET                     ; Return








;----------------------------------------------------
;             Frame Compare?
;----------------------------------------------------
L0A86:  POP     HL              ; Restore HL Register
        POP     DE              ; Restore DE Register
        POP     BC              ; Restore BC Register
        POP     IY              ; Restore IY Register

L0A8B:  LD      A,(0E15Bh)      ; Get Search Counter
        INC     A               ; Increment Search Counter
        LD      (0E15Bh),A      ; Save Search Counter
        JP      Z,L0AE8         ; Search Counter expired, leave routine

        PUSH    IY              ; Save IY Register
        PUSH    BC              ; Save BC Register
        PUSH    DE              ; Save DE Register
        PUSH    HL              ; Save HL Register

        XOR     A               ; A = 0
        LD      (0E127h),A      ;
        LD      (0E17Fh),A      ; Erase Frame Subtract locations
        LD      A,(IY+000h)     ;
        LD      (0E180h),A      ;
        LD      A,(IY+001h)     ;
        LD      (0E181h),A      ;
        LD      A,(IY+002h)     ;
        LD      (0E182h),A      ;

;----------------------------------------------------
;        Wait for frame data from LDPlayer
;----------------------------------------------------
        PUSH    HL              ; Save HL Register
        LD      HL,0E112h       ; HL = LDPlayer Pulse
        LD      A,(HL)          ; Get LDPlayer Pulse
L0AB8:  CP      (HL)            ; Check if any data received
        JR      Z,L0AB8         ; Wait here for frame data
       
        POP     HL              ; Restore HL Register
        LD      A,(0E116h)      ;
        LD      (0E128h),A      ;
        LD      A,(0E117h)      ;
        LD      (0E129h),A      ;
        LD      A,(0E118h)      ;
        LD      (0E12Ah),A      ;
        LD      DE,0E182h       ;
        CALL    L0FCC           ; Call 3-Digit Subtraction
        JR      C,L0AE2         ;       
        LD      HL,(0E181h)     ;
        LD      A,(0E180h)      ;
        OR      H               ;
        OR      L               ;
        JR      Z,L0AE2         ;       
        JR      L0A86           ;       
L0AE2:  POP     HL              ;
        POP     DE              ;
        POP     BC              ;
        POP     IY              ;
        RET                     ;


L0AE8:  INC     SP              ;
        INC     SP              ;
        JP      L0978           ;








;----------------------------------------------------
;
;----------------------------------------------------
L0AED:  PUSH    IY              ; 
        INC     IY              ;
        INC     IY              ;
        INC     IY              ;
        CALL    L0B03           ; Move-Time Validation
        CALL    L0E7A           ; Clear Button and Joystick Data
        POP     IY              ;
        RET                     ; Return






;----------------------------------------------------
;             Move Frame Validation Loop
;----------------------------------------------------
L0AFE:  POP     HL              ; Restore HL Regsiter
        POP     DE              ; Restore DE Register
        POP     BC              ; Restore BC Register
        POP     IY              ; Restore IY Register
;----------------------------------------------------
;               Move Frame Validation
;----------------------------------------------------
;      IY thru IY+2 = Scene Move Frame Address
;----------------------------------------------------
L0B03:  PUSH    IY              ; Save IY Register
        PUSH    BC              ; Save BC Register
        PUSH    DE              ; Save DE Register
        PUSH    HL              ; Save HL Register

;----------------------------------------------------
;               Get Scene Move Frame
;----------------------------------------------------
        LD      A,(IY+000h)     ;
        LD      (0E128h),A      ;
        LD      A,(IY+001h)     ;
        LD      (0E129h),A      ;
        LD      A,(IY+002h)     ;
        LD      (0E12Ah),A      ;
        LD      A,000h          ;
        LD      (0E180h),A      ;
        LD      (0E181h),A      ;

;----------------------------------------------------
;             Add Move Frame Difficulty
;----------------------------------------------------
        LD      D,A             ; D = 0
        LD      A,(0E18Fh)      ; Get DIP Switches 4-11
        AND     00Fh            ; Isolate Move Time (sw 4-8)
        LD      E,A             ; DE = Index (0-15)
        LD      HL,00B67h       ; HL = Difficulty Table
        ADD     HL,DE           ; Add Index to Table Address
        LD      A,(HL)          ; Get Move Frame Adder from table 
        LD      (0E182h),A      ; Save Move Frame Adder
        LD      DE,0E182h       ; Number = Move Frame Adder
        CALL    L0FA1           ; Call 3-Digit Addition
;----------------------------------------------------
;               Get Move Frame
;----------------------------------------------------
        DI                      ; Disable Interrupts (stop clock)
        LD      A,(0E116h)      ;
        LD      (0E128h),A      ;
        LD      A,(0E117h)      ;
        LD      (0E129h),A      ;
        LD      A,(0E118h)      ;
        LD      (0E12Ah),A      ;
        EI                      ; Enable Interrupts

;----------------------------------------------------
;         Compare Move Frame to current Frame
;---------------------------------------------------
        LD      DE,0E182h       ;
        CALL    L0FCC           ; Call 3-Digit Subtraction
        JR      C,L0B61         ;       
        LD      HL,0E181h       ;
        LD      A,(0E180h)      ;
        OR      (HL)            ;
        INC     HL              ;
        OR      (HL)            ;
        JR      Z,L0B61         ;       
        JP      L0AFE           ; Loop back to Move Frame Validation

L0B61:  POP     HL              ; Restore HL Register
        POP     DE              ; Restore DE Register
        POP     BC              ; Restore BC Register
        POP     IY              ; Restore IY Register
        RET                     ; Return




;----------------------------------------------------
;            Difficulty Adjustment Table
;----------------------------------------------------
L0B67:   .DB   000h ;   
         .DB   001h ;   
         .DB   002h ;   
         .DB   003h ;   
         .DB   004h ;   
         .DB   005h ;   
         .DB   006h ;   
         .DB   007h ;   
         .DB   008h ;   
         .DB   009h ;   
         .DB   010h ;   
         .DB   011h ;   
         .DB   012h ;   
         .DB   013h ;   
         .DB   014h ;   
         .DB   015h ;
         
         
         



           
;----------------------------------------------------
;
;----------------------------------------------------
L0B77:  POP     IY              ;

L0B79:  PUSH    IY              ;
        LD      A,(0E15Ah)      ;
        OR      A               ;
        JR      Z,L0BA2         ;       

L0B81:  LD      A,(0E126h)      ; Get Control Register
L0B84:  BIT     1,A             ;
        JR      NZ,L0B81        ; 
             
        LD      A,(0E126h)      ; Get Control Register
        BIT     4,A             ;
        JR      NZ,L0B9C        ;       
;----------------------------------------------------
;             Send PAUSE Command
;----------------------------------------------------
        LD      A,00Ah          ; Command = PAUSE (0Ah) 
        CALL    L207F           ; Send Message to LDPlayer DI
        LD      A,(0E126h)      ; Get Control Register
        SET     4,A             ; Set PAUSE Bit
        LD      (0E126h),A      ; Save Control Register
L0B9C:  CALL    Delay100000     ; Delay 100,000
        JP      L0C7E           ; Sound Bad beep


L0BA2:  LD      A,(0E18Ch)      ; Get DIP Switches 12-19
        BIT     3,A             ; Check Player Immortality (sw 15)
        JR      NZ,L0C1D        ; Immortality set, skip input comparison       


;----------------------------------------------------
;           Compare Joystick movement
;----------------------------------------------------
        LD      HL,0E195h       ; HL = Joystick Data 
        LD      A,(IY+001h)     ; Get Correct Move Data
        OR      A               ; Check if any move exists
        JR      Z,L0C1D         ; No move, so skip ahead
        AND     00Fh            ; Isolate correct joystick move
        JR      Z,L0BD4         ; No joystick move, check FEET and HAND
               
        LD      B,008h          ; B = Joystick Left
        CP      001h            ; Is LEFT the correct move?
        JR      Z,L0BCE         ; Yes, so compare to joystick input
               
        LD      B,004h          ; B = Joystick Down
        CP      002h            ; Is DOWN the correct move?
        JR      Z,L0BCE         ; Yes, so compare to joystick input       

        LD      B,002h          ; B = Joystick Right
        CP      004h            ; Is RIGHT the correct move?
        JR      Z,L0BCE         ; Yes, so compare to joystick input
               
        LD      B,001h          ; B = Joystick Up
        CP      008h            ; Is UP the correct move?
        JR      Z,L0BCE         ; Yes, so compare to joystick input         

L0BCE:  LD      A,(HL)          ; Get Joystick Data
        AND     00Fh            ; Isolate position
        AND     B               ; Compare it to correct move
        JR      NZ,L0C08        ; Move correct, so sound Good BEEP


;----------------------------------------------------
;           Compare FEET and HAND Input
;----------------------------------------------------
L0BD4:  LD      HL,0E192h       ; HL = Button Data
        LD      A,(IY+001h)     ; Get Correct Move Data
        AND     0F0h            ; Isolate Hand and Feet
        JR      Z,L0C26         ; No button, just joystick so do wrong move
             
        CP      0F0h            ; Allow FEET or HAND?
        JR      Z,L0BFA         ; Yes, so check both

        CP      090h            ; Allow FEET?
        JR      Z,L0BF0         ; Yes, go check FEET 

;----------------------------------------------------
;                Check HAND Button
;----------------------------------------------------             
        LD      B,030h          ; B = HAND Button
        LD      A,(HL)          ; Get Button Data
        AND     030h            ; Check HAND button
        AND     B               ; Compare button to correct move
        JR      NZ,L0C08        ; Button correct, so sound Good Beep       
        JR      L0C26           ; Wrong move, jump ahead       

;----------------------------------------------------
;                Check FEET Button
;----------------------------------------------------
L0BF0:  LD      B,00Ch          ; B = FEET Button
        LD      A,(HL)          ; Get Button Data
        AND     00Ch            ; Check FEET button
        AND     B               ; Compare button to correct move
        JR      NZ,L0C08        ; Move correct, sound Good Beep       
        JR      L0C26           ; Wrong move, jump ahead

;----------------------------------------------------
;             Check FEET or HAND Button
;----------------------------------------------------
L0BFA:  LD      B,03Ch          ; B = FEET and HAND buttons
        LD      A,(HL)          ; Get Button Data
        AND     030h            ; Check HAND Button
        AND     B               ; Compare button to correct move
        JR      NZ,L0C08        ; Move correct, sound Good Beep

        LD      A,(HL)          ; Get Button Data
        AND     00Ch            ; Check FEET Button
        AND     B               ; Compare button to correct move
        JR      Z,L0C26         ; Wrong move, jump ahead


;----------------------------------------------------
;  Correct Move:  Sound Beep and Award 5,000 Points
;----------------------------------------------------
L0C08:  CALL    GoodBeep        ; Sound Good Beep
        XOR     A               ; A = 0
        LD      (0E127h),A      ; Bonus 10000000/1000000 = 0
        LD      (0E128h),A      ; Bonus 100000/10000 = 0
        LD      (0E12Ah),A      ; Bonus 10/1 = 0
        LD      A,050h          ; Set 5,000 Points
        LD      (0E129h),A      ; Bonus 1000/100 = 50
        CALL    L0F8F           ; Award Points and Update Score Display

L0C1D:  CALL    L0E4C           ; Erase Hint
        CALL    L0E7A           ; Clear Button and Joystick Data
        POP     IY              ; Restore IY Register
        RET                     ; Return


;----------------------------------------------------
;         Check for Incorrect Joystick Move
;----------------------------------------------------
L0C26:  LD      HL,0E195h       ; HL = Joystick Data
        LD      A,(IY+002h)     ; Get Incorrect Move Data
        OR      A               ; Are there incorrect moves?
        JR      Z,L0C83         ; No, so jump ahead       

        LD      B,000h          ;
        AND     00Fh            ;
        JR      Z,L0C55         ;
             
        LD      B,00Fh          ;

        BIT     0,A             ;
        JR      NZ,L0C3D        ;       
        RES     3,B             ;

L0C3D:  BIT     1,A             ;
        JR      NZ,L0C43        ;       
        RES     2,B             ;

L0C43:  BIT     2,A
        JR      NZ,L0C49               
        RES     1,B

L0C49:  BIT     3,A             ;
        JR      NZ,L0C4F        ;       
        RES     0,B             ;

L0C4F:  LD      A,(HL)          ; Get Joystick Input
        AND     00Fh            ; Isolate Joystick data
        AND     B               ; Compare to incorrect move
        JR      NZ,L0C7E        ; Move is incorrect, sound bad beep       

;----------------------------------------------------
;         Check for Incorrect Button
;----------------------------------------------------
L0C55:  LD      HL,0E192h       ; HL = Button Data
        LD      A,(IY+002h)     ; Get Incorrect Move
        AND     0F0h            ; Isolate Button Data
        JR      Z,L0C83         ;       

        CP      090h            ;
        JR      Z,L0C6B         ;       

        LD      B,030h          ;
        LD      A,(HL)          ;
        AND     030h            ;
        AND     B               ;
        JR      NZ,L0C7E        ; Move incorrect, sound bad beep       

L0C6B:  LD      A,(IY+002h)     ;
        AND     0F0h            ;
        CP      090h            ;
        JR      NZ,L0C83        ;       
        LD      B,00Ch          ;
        LD      A,(HL)
        AND     00Ch
        AND     B
        JR      NZ,L0C7E        ; Move is incorrect, so sound bad beep       
        JR      L0C83                   

;----------------------------------------------------
;        Incorrect Move found, sound bad beep
;----------------------------------------------------
L0C7E:  CALL    BadBeep         ; Sound Bad Beep
        JR      L0CE1           ; Start Death Sequence       

;----------------------------------------------------
;       Check if Move Frame Window has expired
;----------------------------------------------------
L0C83:  LD      DE,00006h       ; Index to Move Frame
        ADD     IY,DE           ;
        LD      A,(IY+000h)     ;
        LD      (0E180h),A      ;
        LD      A,(IY+001h)     ;
        LD      (0E181h),A      ;
        LD      A,(IY+002h)     ;
        LD      (0E182h),A      ;
        LD      A,000h          ;
        LD      (0E128h),A      ;
        LD      (0E129h),A      ;
        LD      D,A             ;
        LD      A,(0E18Fh)      ;
        AND     00Fh            ;
        LD      E,A             ;
        LD      HL,00CE8h       ; HL = start of data
        ADD     HL,DE           ;
        LD      A,(HL)          ;
        LD      (0E12Ah),A      ;
        LD      DE,0E182h       ;
        CALL    L0FCC           ; Call 3-Digit Subtraction
        DI                      ; Disable Interrupts
        LD      A,(0E116h)      ;
        LD      (0E128h),A      ;
        LD      A,(0E117h)      ;
        LD      (0E129h),A      ;
        LD      A,(0E118h)      ;
        LD      (0E12Ah),A      ;
        EI                      ; Enable Interrupts
        LD      DE,0E182h       ;
        CALL    L0FCC           ; Call 3-Digit Subtraction
        JR      C,L0CE1         ; Move Window expired, jump ahead       

        LD      HL,0E181h       ;
        LD      A,(0E180h)      ;
        OR      (HL)            ;
        INC     HL              ;
        OR      (HL)            ;
        JR      Z,L0CE1         ;       
        JP      L0B77           ;

;----------------------------------------------------
;       Window expired with no move, start Death
;----------------------------------------------------
L0CE1:  POP     IY              ; Restore Move Address
        INC     SP              ;
        INC     SP              ;
        JP      L0CF8           ; Start Death Sequence 


;----------------------------------------------------
;               data bytes
;----------------------------------------------------
L0CE8:  .DB   000h, 000h, 000h, 000h
        .DB   000h, 000h, 000h, 000h
        .DB   002h, 004h, 006h, 008h   
        .DB   010h, 012h, 014h, 016h







;----------------------------------------------------
;               Start Death Sequence
;----------------------------------------------------
L0CF8:  CALL    EraseActionOrStick

        LD      A,(0E126h)      ; Get Control Register
        SET     2,A             ; Set ?
        LD      (0E126h),A      ; Save Control Register

        LD      (0E1AFh),IX     ;
        LD      (0E1B1h),IY     ;
        LD      A,(0E15Ah)      ;
        OR      A               ;
        JR      NZ,L0D30        ;       

        PUSH    IY              ;
        POP     DE              ;
        LD      HL,(0E1B8h)     ;
        XOR     A               ;
        SBC     HL,DE           ;
        LD      A,H             ;
        OR      L               ;
        JR      Z,L0D29         ;       

        LD      A,001h          ;
        LD      (0E1B7h),A      ;
        LD      (0E1B8h),IY     ;
        JR      L0D30           ;       

L0D29:  LD      A,(0E1B7h)      ;
        INC     A               ;
        LD      (0E1B7h),A      ;

L0D30:  LD      A,(0E1AEh)      ; Get Number of Lives Remaining
        OR      A               ; Check if any lives left
        JR      Z,L0DA3         ; No lives left so skip ahead
        ADD     A,099h          ; Add 99 Lives
        DAA                     ; Convert to decimal
        LD      (0E1AEh),A      ; Save Number of Lives Remaining

;----------------------------------------------------
;       Read Death Scene Starting Frame Number 
;----------------------------------------------------
        LD      DE,00009h       ; Index to death scene
        ADD     IY,DE           ; Add to move index
        CALL    L095A           ; Play Death Scene for Incorrect Move
        LD      A,(0E15Ah)      ;
        OR      A               ;
        JR      NZ,L0D9B        ;       
        LD      A,000h          ;
        LD      (0E122h),A      ;
        LD      IY,(0E1B1h)     ;
        PUSH    IY              ;
        POP     IX              ; IX = IY
        LD      DE,0000Ch       ; Index to End Frame of Death Address
        ADD     IX,DE           ; Index into move table

;----------------------------------------------------
;         Read Death Scene Ending Frame Number 
;----------------------------------------------------
        XOR     A               ; A = 0
        LD      (0E17Fh),A      ; Erase Frame Subtract locations
        LD      A,(IX+000h)     ; Get Frame Number Byte 1 from ROM
        LD      (0E180h),A      ; Store Frame Number Byte 1
        LD      A,(IX+001h)     ; Get Frame Number Byte 2 from ROM 
        LD      (0E181h),A      ; Store Frame Number Byte 2
        LD      A,(IX+002h)     ; Get Frame Number Byte 3 from ROM
        LD      (0E182h),A      ; Store Frame Number Byte 3

        LD      A,(0E186h)      ; Get DIP Switches 28-35
        BIT     2,A             ; Check Play Hanging Scene?
        JR      Z,L0D90         ; Don't play scene, so skip ahead       

;----------------------------------------------------
;         Set Frame Number for Hanging Scene
;       Hanging Scene = Ending Scene Frame - 272
;----------------------------------------------------
        XOR     A               ; A = 0
        LD      (0E127h),A      ; Store 0
        LD      (0E128h),A      ; Store 0
        LD      A,002h          ; A = 02
        LD      (0E129h),A      ; Store 2
        LD      A,072h          ; A = 72
        LD      (0E12Ah),A      ; Store 72

        LD      DE,0E182h       ; Subtract 272 from Starting Frame
        CALL    L0FCC           ; Call 3-Digit Subtraction

;----------------------------------------------------
;      Wait until Death Scene finished playing
;----------------------------------------------------
L0D90:  LD      IX,0E180h       ; Frame Number Address
        CALL    L0DAF           ; Wait until frame number reached
        LD      IX,(0E1AFh)     ;

L0D9B:  LD      A,(0E126h)      ; Get Control Register
        RES     2,A             ;
        LD      (0E126h),A      ;

L0DA3:  LD      A,(0E1AEh)      ; Get Number of Lives Remaining
        OR      A               ; Check if any lives left
        CALL    Z,L12F0         ; No lives left so check BUY-IN
        JP      L1EA2           ; Swap players






;----------------------------------------------------
;         Wait until frame number reached
;     IX = Address of Target frame
;----------------------------------------------------
L0DAD:  POP     IX              ; Get Frame Number Address
L0DAF:  PUSH    IX              ; Save Frame Number Address
        LD      HL,0E116h       ; HL = Odd Frame Count
        LD      B,003h          ; 3 bytes (6 digits) to compare
L0DB6:  LD      A,(HL)          ; Get Current Frame
        CP      (IX+000h)       ; Compare to Target Frame
        JR      Z,L0DDE         ; Frame bytes equal now check next byte       
        JR      NC,L0DC0        ; Target frame passed, so log error       
        JR      L0DAD           ; Loop back until target frame matches       

;----------------------------------------------------
;         Wait for next frame from LDPlayer
;----------------------------------------------------
L0DC0:  LD      A,(0E112h)      ; Get LDPlayer Pulse
        LD      B,A             ; B = Pulse
L0DC4:  LD      A,(0E112h)      ; Get LDPlayer Pulse
        CP      B               ; See if it has changed
        JR      Z,L0DC4         ; Wait until frame count arrives

        LD      A,(0E123h)      ;
        INC     A               ;
        LD      (0E123h),A      ;

        LD      A,(0E122h)      ; Get errors
        INC     A               ; Increment errors
        LD      (0E122h),A      ; Save errors

        CP      002h            ; Do we have more than 2 errors?
        JR      C,L0DAD         ; Not yet, so continue trying       
        JR      L0DE3           ; Too many errors, give up and just continue

L0DDE:  INC     HL              ; Next byte to compare
        INC     IX              ; Next byte to compare
        DJNZ    L0DB6           ; Loop until all digits compared       

L0DE3:  POP     IX              ; Restore Frame Number Address
        LD      A,000h          ; Clear out errors
        LD      (0E122h),A      ; Save errors
        RET                     ; Return







;----------------------------------------------------
;            Show Stick and Action Hints     
;----------------------------------------------------
L0DEB:  LD      A,(0E186h)      ; Get DIP Switches 28-35
        BIT     5,A             ; Check Show Hints (sw 33)
        RET     Z               ; No Hints, so just return

        PUSH    IX              ; Save IX Register
        PUSH    IY              ; Save IY Register
        PUSH    BC              ; Save BC Register

        LD      A,(IY+001h)     ; Get correct move
        AND     00Fh            ; Isolate joystick move
        JR      Z,L0E21         ; No Stick move, check Action
        CALL    L2353           ; Wait for Comm Ready
        PUSH    HL              ; Save HL Register
        LD      HL,003A4h       ; Cursor Position
        CALL    L2212           ; Set Cursor and Print Text
;----------------------------------------------------
L0E07: .TEXT "   \ STICK ~   "
       .DB   000h             
;----------------------------------------------------
L0E17:  POP     HL              ; Restore HL Register
        CALL    L2381           ;
        POP     BC              ; Restore BC Register
        POP     IY              ; Restore IY Register
        POP     IX              ; Restore IX Register
        RET                     ; Return

;----------------------------------------------------
;              Check for Action Move Hint
;----------------------------------------------------
L0E21:  LD      A,(IY+001h)     ; Get correct move
        AND     0F0h            ; Isolate Action move
        JR      Z,L0E46         ; No Action move, so skip to end
        CALL    L2353           ; Wait for Comm Ready
        PUSH    HL              ; Save HL Register
        LD      HL,003A4h       ; Cursor Position
        CALL    L2212           ; Set Cursor and Print Text
;----------------------------------------------------
L0E32:  .TEXT   "  \ ACTION ~   "
        .DB   000h     
;----------------------------------------------------
L0E42:  POP     HL              ; Restore HL Register
        CALL    L2381           ;
L0E46:  POP     BC              ; Restore BC Register
        POP     IY              ; Restore IY Register
        POP     IX              ; Restore IX Register
        RET                     ; Return





;----------------------------------------------------
;                  Erase Hint       
;----------------------------------------------------
L0E4C:  PUSH    IX              ; Save IX Register
        PUSH    IY              ; Save IY Register
        PUSH    BC              ; Save BC Register
        LD      A,(IY+001h)     ; Get correct move
L0E54:  OR      A               ; Was there a move
        JR      Z,L0E46         ; No move, so just return       
        CALL    L2353           ; Wait for Comm Ready
        PUSH    HL              ; Save HL Register
        LD      HL,003A3h       ; Cursor Position
        CALL    L2212           ; Set Cursor and Print Text     
;----------------------------------------------------
L0E61:  .TEXT   "                 "
        .DB   000h     
;----------------------------------------------------         
L0E73:  POP     HL              ; Restore HL Register
        POP     BC              ; Restore BC Register
        POP     IY              ; Restore IY Register
        POP     IX              ; Restore IX Register
        RET                     ; Return





;----------------------------------------------------
;            Clear Button Data
;----------------------------------------------------
L0E7A:  PUSH    AF              ; Save AF Register
        LD      A,(0E192h)      ; Get Button Data
        RES     2,A             ; Clear PLAYER1/FEET
        RES     3,A             ; Clear PLAYER2/FEET
        RES     5,A             ; Clear HAND-Left
        RES     4,A             ; Clear HAND-Right
        LD      (0E192h),A      ; Write Button Data
;----------------------------------------------------
;           Clear Joystick Data
;----------------------------------------------------
L0E89:  LD      A,(0E195h)      ; Get Joystick Data
        RES     0,A             ; Clear UP
        RES     1,A             ; Clear RIGHT
        RES     2,A             ; Clear DOWN
        RES     3,A             ; Clear LEFT
        LD      (0E195h),A      ; Write Joystick Data
        POP     AF              ; Restore AF Register
        RET                     ; Return



     


;----------------------------------------------------
;            Do GOOD Beep (BEEP)
;----------------------------------------------------
GoodBeep:
L0E99:  LD      A,(0E114h)      ;
        SET     0,A             ;
        LD      (0E114h),A      ;
        OUT     (046h),A        ; Beep
        LD      A,002h          ;
        LD      (0E125h),A      ;
        RET                     ; Return






;----------------------------------------------------
;           Do Bad BEEP (BOOP)
;----------------------------------------------------
BadBeep:
L0EA9:  LD      A,(0E114h)      ;
        SET     1,A             ;
        LD      (0E114h),A      ;
        OUT     (046h),A        ;
        LD      A,004h          ;
        LD      (0E110h),A      ;
        RET                     ; Return






;----------------------------------------------------
;                    Overlay Score
;----------------------------------------------------
OverlayScore:
L0EB9:  LD      A,(0E186h)      ; Get DIP Switches 28-35
L0EBC:  BIT     4,A             ; Check Display Overlay (sw 32)
        RET     Z               ; Overlay disabled, so just return

        CALL    L2353           ; Wait for Comm Ready

        LD      DE,00000h       ; Player1 Location X = 0, Y = 0
        LD      A,(0E1A9h)      ; Get Player Number
        CP      001h            ; Is it Player 1?
        JP      Z,L0ED0         ; Yes, so jump ahead
        LD      DE,01E00h       ; Player2 Location X = 30, Y = 0

L0ED0:  LD      HL,0E1AAh       ; HL = Score Address
        LD      B,004h          ; 4 Bytes in score 
        LD      C,000h          ;
        EX      AF,AF'          ;
        LD      A,000h          ;
        EX      AF,AF'          ;
                                 
L0EDB:  LD      A,(HL)          ; Get Score byte
        RRC     A               ;
        RRC     A               ;
        RRC     A               ;
        RRC     A               ;
        AND     00Fh            ;
        JR      NZ,L0EEE        ;       
        LD      A,C             ;
        OR      A               ;
        JR      Z,L0EF4         ;       
        LD      A,000h          ;

L0EEE:  OR      030h            ; Make digit into character
        LD      C,A             ; C = Character
        CALL    L0F1B           ; Send Character

L0EF4:  INC     D               ; Location X = X + 1
        LD      A,(HL)          ;
        AND     00Fh            ;
        JR      NZ,L0F08        ;       
        LD      A,B             ;
        CP      001h            ;
        LD      A,000h          ;
        JP      Z,L0F08         ;
        LD      A,C             ;
        OR      A               ;
        JR      Z,L0F0E         ;       
        LD      A,000h          ;
L0F08:  OR      030h            ; Make digit into character
        LD      C,A             ;
        CALL    L0F1B           ;
L0F0E:  INC     D               ;
        INC     HL              ;
        DJNZ    L0EDB           ;       

        LD      A,07Eh          ; A = Character Left Triangle
        CALL    L2233           ; Print one Character to Text Display
        CALL    L0F39           ; Print Little Man characters
        RET                     ; Return





;----------------------------------------------------
;              Send Character
;----------------------------------------------------
L0F1B:  PUSH    AF
        EX      AF,AF'
        PUSH    AF
        EX      AF,AF'
        POP     AF
        OR      A
        JR      NZ,L0F2D               
        LD      A,05Ch          ; A = Character
        CALL    L2233           ; Print one Character to Text Display
        EX      AF,AF'          ;
        LD      A,001h          ;
        EX      AF,AF'          ;
        INC     D               ;
L0F2D:  POP     AF              ;
        CALL    L2233           ; Print one Character to Text Display
        PUSH    AF              ; Save AF Register
        PUSH    BC              ; Save BC Register
        CALL    L2353           ; Wait for Comm Ready
        POP     BC              ; Restore BC Register
        POP     AF              ; Restore AF Register
        RET                     ; Return






;----------------------------------------------------
;     Print a Little Man for each life remaining
;----------------------------------------------------
L0F39:  LD      A,(0E1AEh)      ; Get Number of Lives Remaining
        OR      A               ; Test number of lives
        RET     Z               ; If no lives left then just return

        CALL    L2353           ; Wait for Comm Ready

        LD      B,006h          ; Loop = 6
        LD      A,(0E1AEh)      ; Get Number of Lives remaining
        CP      B               ; Are there more than 6 lives left?
        JR      C,L0F4A         ; Less than 6 lives so skip ahead       
        LD      A,B             ; Set number of lives to 6

L0F4A:  LD      B,A             ; B= Number of Lives remaining
        LD      A,(0E1A9h)      ; Get Player Number
        CP      001h            ; Check for Player1
        JP      Z,L0F6F         ; Jump ahead and show Player1 lives

        LD      DE,01400h       ; Location X = 20, Y = 0
        LD      A,05Ch          ; A = Character
        CALL    L2233           ; Print one Character to Text Display

;----------------------------------------------------
;        Print a little man for each life
;----------------------------------------------------
        LD      DE,01500h       ; Location X = 21, Y = 0
L0F5E:  LD      A,090h          ; A = Character Little Man
        CALL    L2233           ; Print one Character to Text Display
        CALL    L0F8B           ; Wait for Comm
        INC     D               ; Location X = X + 1
        DJNZ    L0F5E           ; Loop until all lives are shown     

        LD      A,07Eh          ; A = Character Left Triangle
        CALL    L2233           ; Print one Character to Text Display
        RET                     ; Return


L0F6F:  LD      DE,01400h       ; Location X = 20, Y = 0
        LD      A,07Eh          ; A = Character Left Triangle
        CALL    L2233           ; Print one Character to Text Display

        LD      DE,01300h       ; Location X = 19, Y = 0
L0F7A:  LD      A,090h          ; A = Character
        CALL    L2233           ; Print one Character to Text Display

        CALL    L0F8B           ; Wait for Comm
        DEC     D               ; Location X = X - 1
        DJNZ    L0F7A           ;       
        LD      A,05Ch          ; A = Character
        CALL    L2233           ; Print one Character to Text Display
        RET                     ; Return





;----------------------------------------------------
;              Wait for 1 Comm
;----------------------------------------------------
L0F8B:  CALL    L2353           ; Wait for Comm Ready
        RET                     ; Return





;----------------------------------------------------
;       Award Points and Update Score Display
;     E127-E12A  = Points to add to score
;----------------------------------------------------
L0F8F:  PUSH    BC               ; Save BC Register
        PUSH    DE               ; Save DE Register
        PUSH    HL               ; Save HL Register
        LD      B,004h           ; 4 digits to add
        LD      DE,0E1ADh        ; Load Score
        CALL    L0FBF            ; Call Addition
        CALL    L0EB9            ; Overlay Score
        POP     HL               ; Restore HL Register
        POP     DE               ; Restore DE Register
        POP     BC               ; Restore BC Register 
        RET                      ; Return





;----------------------------------------------------
;               3-Digit Addition
;----------------------------------------------------
;       DE = Last location which to add to (ones)
;----------------------------------------------------
L0FA1:  LD      B,003h          ; 3 digits to add
        CALL    L0FBFh          ; Call BCD Addition
        LD      HL,L0000        ; HL = 00000h
        LD      (0E127h),HL     ; Erase Temp Add/Subtract location
        LD      (0E129h),HL     ; Erase Temp Add/Subtract location
        RET                     ; Return






;----------------------------------------------------
;               2-Digit Addition
;----------------------------------------------------
;       DE = Last location which to add to (ones)
;----------------------------------------------------
L0FB0:  LD      B,002h          ; 2 digits to add
        CALL    L0FBF           ; Call BCD Addition
        LD      HL,L0000        ; HL = 00000h
        LD      (0E127h),HL     ; Erase Temp Add/Subtract location
        LD      (0E129h),HL     ; Erase Temp Add/Subtract location
        RET                     ; Return





;----------------------------------------------------
;                BCD Addition 
;----------------------------------------------------
;         DE = Last location which to add to (ones)
;          B = Number of digits to add
;  E127-E12A = Value which to add (temp)
;----------------------------------------------------
L0FBF:  LD      HL,0E12Ah       ; Pointer to temp add location
        OR      A               ; Clear Carry
L0FC3:  LD      A,(DE)          ; Get adder value
        ADC     A,(HL)          ; Add to DE
        DAA                     ; Convert to decimal
        LD      (DE),A          ; Store total
        DEC     DE              ; Point to next digit (total)
        DEC     HL              ; Point to next digit (adder)
        DJNZ    L0FC3           ; Loop until all digits added       
        RET                     ; Return






;----------------------------------------------------
;               3-Digit Subtraction
;----------------------------------------------------
;           DE = Location which to subtract from
;    E127-E12A = Value which to subtract (temp)
;----------------------------------------------------
L0FCC:  LD      B,003h          ; 3 digits to subtract
        CALL    L0FEA           ; Call BCD Subtraction
        LD      HL,00000h       ; HL = 00000h
        LD      (0E127h),HL     ; Erase Temp Add/Subtract location
        LD      (0E129h),HL     ; Erase Temp Add/Subtract location
        RET                     ; Return





;----------------------------------------------------
;               2-Digit Subtraction
;----------------------------------------------------
;           DE = Location which to subtract from
;    E127-E12A = Value which to subtract (temp)
;----------------------------------------------------
L0FDB:  LD      B,002h          ; 2 digits to subtract
        CALL    L0FEA           ; Call BCD Subtraction
        LD      HL,00000h       ; HL = 00000h
        LD      (0E127h),HL     ; Erase Temp Add/Subtract location
        LD      (0E129h),HL     ; Erase Temp Add/Subtract location
        RET                     ; Return






;----------------------------------------------------
;                BCD Subtraction 
;----------------------------------------------------
;           DE = Location which to subtract from
;           B  = Number of digits to subtract
;    E127-E12A = Value which to subtract (temp)
;----------------------------------------------------
L0FEA:  LD      HL,0E12Ah       ; Pointer to temp subtraction location
        OR      A               ; Clear carry
L0FEE:  LD      A,(DE)          ; Get subtraction value
        SBC     A,(HL)          ; Subtract value
        DAA                     ; Convert to decimal
        LD      (DE),A          ; Store result
        DEC     DE              ; Point to next digit
        DEC     HL              ; Point to next digit
        DJNZ    L0FEE           ; Loop until all digits subtracted       
        RET                     ; Return 