FUNCTION soda2_read2dbuffer, lun, pop
   ;FUNCTION to read in 2dc buffers
   ;returns a structure with the parameters: tas, starttime, difftime, image

   ;lun is the file logical unit number
   ;Aircraft specifies the source of the data
   ;lasttime is time of previous buffer - used in formats where
   ;   only the start or end time of a buffer is recorded
   ;
   ;pop is pointer to op structure containing format, res=res, probetype
   ;AB 4/2009
   ;Copyright © 2016 University Corporation for Atmospheric Research (UCAR). All rights reserved.


   point_lun,-lun,pointer ;save pointer
   nullbuffer={image:0,tas:0,time:0,difftime:0,eof:1,pointer:pointer,overload:0,date:0}
   IF eof(lun) THEN return,nullbuffer

   IF (*pop).format eq 'RAF' THEN BEGIN
      ;FORMAT OF BUFFER
      A={probetype:0b, probenumber:0b, hours:0s, minutes:0s, $
        seconds:0s, year:0s, month:0s, day:0s, tas:0s, milliseconds:0s, $
        overload:0s, image:ulonarr(1024) }
      IF ((*pop).probetype eq 'F2DC') or ((*pop).probetype eq 'F2DC_v2') or ((*pop).probetype eq 'F2DP') THEN $
        A={probetype:0b, probenumber:0b, hours:0s, minutes:0s, $
        seconds:0s, year:0s, month:0s, day:0s, tas:0s, milliseconds:0s, $
        overload:0s, image:ulon64arr(512)}


      IF pointer lt 157 THEN BEGIN    ;skip over the xml tag
         point_lun,lun,0
         s=bytarr(1000)
         readu,lun,s
         pos=strpos(s,'</PMS2D>')
         point_lun,lun,pos+9
         IF pos eq -1 THEN BEGIN   ;New identifier in 2011
            pos=strpos(s,'</OAP>')
            point_lun,lun,pos+7
            IF (*pop).subformat ne 3 THEN stop ;Using old subformat, leads to bad TAS
         ENDIF ELSE BEGIN
            IF (*pop).subformat eq 3 THEN stop ;Using new subformat, leads to bad TAS
         ENDELSE
      ENDIF

      REPEAT BEGIN
         f=fstat(lun)
         IF (f.size-f.cur_ptr lt 4116) THEN return, nullbuffer
         readu,lun,A
         A=swap_endian(A)
         probeid=string([a.probetype,a.probenumber])   ;e.g. C4, C6, P1
      ENDREP UNTIL (probeid eq (*pop).probeid)

      IF (*pop).subformat eq 3 THEN tas=a.tas ELSE tas=A.tas*125.0/255.0 ;TAS format changed in 2011
      time=A.hours*3600d + A.minutes*60d + A.seconds*1d + A.milliseconds/1000d  ;Time of LAST SLICE in buffer
      difftime=0
      time=time+(*pop).timeoffset
      date=julday(a.month,a.day,a.year>1)
      overload=a.overload/1000.0   ;Convert to seconds
      ;print,a.hours,a.minutes,a.seconds,a.milliseconds,a.year,a.month,a.day,a.tas,a.image[0]
      return,{image:A.image,tas:tas,time:time,difftime:difftime,eof:0,pointer:pointer,overload:overload,date:date,a:a}
   ENDIF


   IF (*pop).format eq 'SEA' THEN BEGIN
      eofile=0
      CASE 1 OF
        ((*pop).probetype eq 'CIP') or ((*pop).probetype eq 'CIPG'):BEGIN
           q=fstat(lun)
           IF (*pop).fixedtas gt 0 THEN tas=(*pop).fixedtas ELSE tas=100.0
           A=readseabuffer_caps(lun, probetype='CIP', tag=(*pop).seatag[0])
        END
        ELSE: BEGIN
           ;This should work for 1D2D, HVPS, and Hail Spectrometer.  Maybe legacy 2DC (untested).
           A=read2dseabuffer(lun, res=(*pop).res, probetype=(*pop).probetype, tags=(*pop).seatag)
           IF a.eof eq 0 THEN tas=a.tas
           ;IF pversion.tlfix THEN A.image=fix2dimage(A.image)
         END
      ENDCASE
      IF a.eof eq 1 THEN return, nullbuffer
      IF a.year gt 0 THEN date=julday(a.month,a.day,a.year) ELSE date=0
      return, {time:hms2sfm(a.starttime)+(*pop).timeoffset, stoptime:hms2sfm(a.stoptime)+(*pop).timeoffset, image:a.image, $
               difftime:0.0, eof:eofile, tas:tas, pointer:pointer, date:date, overload:0}
   ENDIF

   IF (*pop).format eq 'DMT' THEN BEGIN
      buffer={year:0S, month:0S, day:0S, hour:0S, minute:0S, second:0S, $
        millisecond:0S, weekday:0S, cimage:bytarr(4096)}
      dummy=bytarr(12) ; this is to read in the 12 bytes of data after an image (no useful info contained)

      q=fstat(lun)
      eofile=0
      IF q.size-q.cur_ptr ge 4112 THEN readu,lun,buffer ELSE eofile=1
      IF (*pop).subformat eq 0 THEN readu,lun,dummy
      divisor=1000d
      IF (*pop).subformat eq 2 THEN divisor=100d  ;Account for centisecond/millisecond error in PADS files
      time=buffer.hour*3600d + buffer.minute*60d + buffer.second*1d + buffer.millisecond/divisor
      IF buffer.year gt 0 THEN date=julday(buffer.month,buffer.day,buffer.year) ELSE date=0
      IF (*pop).fixedtas gt 0 THEN tas=(*pop).fixedtas ELSE tas=100.0

      return, {time:time+(*pop).timeoffset, image:buffer.cimage, difftime:0.0, eof:eofile, tas:tas, pointer:pointer, date:date, overload:0}
   ENDIF

   IF (*pop).format eq 'SPEC' THEN BEGIN
      buffer={year:0s, month:0s, dummy:0s, day:0s, hour:0s, minute:0s, second:0s, millisecond:0s}
      readu,lun,buffer
      time=buffer.hour*3600d + buffer.minute*60d + buffer.second*1d + buffer.millisecond/1000d
      IF buffer.year gt 0 THEN date=julday(buffer.month,buffer.day,buffer.year) ELSE date=0
      IF (*pop).fixedtas gt 0 THEN tas=(*pop).fixedtas ELSE tas=100.0

      return, {time:time+(*pop).timeoffset, image:0, difftime:0.0, eof:0, tas:tas, pointer:pointer, date:date, overload:0}
   ENDIF

   IF (*pop).format eq 'TXT' THEN BEGIN
      ;Text data from the OAP model, read in up to 1024 slices and package into a buffer
      point_lun,lun,0   ;Read header
      s=''
      readf,lun,s  ;Read header
      v=str_sep(strcompress(s),' ')
      tas=float(v[7])
      IF pointer gt 0 THEN point_lun,lun,pointer  ;Move to original position

      image=bytarr((*pop).numdiodes, 1024)
      startslice=intarr(500)
      nslices=intarr(500)
      particletime=dblarr(500)
      inttime=dblarr(500)
      n=0L
      REPEAT BEGIN
         readf,lun,s   ;Should be the start of a new particle
         IF strmid(s,0,1) ne '*' THEN stop,'File out of sync.'
         v=str_sep(strcompress(s),' ')
         nslices[n]=v[2]
         particletime[n]=v[3]
         inttime[n]=v[4]
         IF startslice[n]+nslices[n] lt 1024 THEN BEGIN
            roi=bytarr((*pop).numdiodes, nslices[n])
            readf,lun,roi,format='('+v[1]+'i1)'
            image[*,startslice[n]:startslice[n]+nslices[n]-1]=roi
            startslice[n+1]=startslice[n]+nslices[n]+1  ;Final +1 is for spacing
            n++
            point_lun,-lun,pnextparticle
         ENDIF
      ENDREP UNTIL (eof(lun) eq 1) or (startslice[n]+nslices[n] ge 1024)
      point_lun,lun,pnextparticle  ;Reset the pointer to the start of the unread particle

      date=julday(1,1,2000)
      return, {time:particletime[0], image:image, difftime:0.0, eof:0, tas:tas, pointer:pointer, date:date, overload:0, $
               startslice:startslice[0:n-1], nslices:nslices[0:n-1], particletime:particletime[0:n-1], inttime:inttime[0:n-1]}
   ENDIF

END
