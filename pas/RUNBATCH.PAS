{$I Switches}
{$A-,B-,F+,G-,I-,O+,R-,S+,V+,X+,L+}
unit runbatch;
{ fand TASK --source-in, --source-out, --export, --export-sql, --import; see HOWTO.txt }
interface
function FandBatchRun(const Task,Op,Arg:string):integer;
implementation
uses dos, sysutils, base, drivers, access, oaccess, obaseww, rdrun, runproj,
     compile, fandcp, fanddos;
procedure Ovr; begin end;
var
  Opened:boolean;
  Aborted:boolean;
  Outcome:integer;
  Warnings:longint;
procedure Say(const Utf8:ansistring);
begin writeln(StdErr,'fand: ',Utf8) end;
procedure Warn(const Utf8:ansistring);
begin Say(Utf8); inc(Warnings) end;
function U(const S:ansistring):ansistring;
begin U:=S852ToUtf8(S) end;
function TrimRightCh(const S:ansistring; C:char):ansistring;
var n:longint;
begin n:=length(S); while (n>0) and (S[n]=C) do dec(n); TrimRightCh:=copy(S,1,n) end;
function IStr(N:int64):ansistring;
var s:ansistring;
begin str(N,s); IStr:=s end;
function LongToAnsi(X:LongStrPtr):ansistring;
var s:ansistring;
begin SetLength(s,X^.LL); if X^.LL>0 then move(X^.A,s[1],X^.LL); LongToAnsi:=s end;
function AnsiToLong(const S:ansistring):LongStrPtr;
var x:LongStrPtr; n:longint;
begin
  n:=length(S); if n>$FFF0 then n:=$FFF0;
  x:=GetStore(n+2); x^.LL:=n; if n>0 then move(S[1],x^.A,n); AnsiToLong:=x;
end;
procedure ReportCompileErr;
var s,t,r:ansistring; line,col,i:longint; x:LongStrPtr; p:pointer; cf:FileDPtr; cr:pointer;
begin
  s:=MsgLine;
  if (InpRdbPos.R=CRdb) and (InpRdbPos.IRec>0) and not CRdb^.Encrypted then begin
    cf:=CFile; cr:=CRecPtr; MarkStore(p);
    CFile:=Chpt; CRecPtr:=GetRecSpace; ReadRec(InpRdbPos.IRec);
    x:=_LongS(ChptTxt); t:=LongToAnsi(x);
    line:=1; col:=1;
    for i:=1 to CurrPos-1 do
      if i>length(t) then break
      else if t[i]=#13 then begin inc(line); col:=1 end
      else if t[i]<>#10 then inc(col);
    if CRdb^.ChainBack<>nil then r:=U(CRdb^.FD^.Name)+': ' else r:='';
    Warn(r+'chapter '+IStr(InpRdbPos.IRec)+' '+TrimRightCh(_ShortS(ChptTyp),' ')+' '+
         U(TrimRightCh(_ShortS(ChptName),' '))+', line '+IStr(line)+' column '+IStr(col)+
         ': '+U(s));
    ReleaseStore(p); CFile:=cf; CRecPtr:=cr end
  else Warn(U(s));
end;
function Compiled:boolean;
begin
  CompileFD:=true;
  if CompileRdb(false,true,false) then Compiled:=true
  else begin Compiled:=false; ReportCompileErr end;
end;
function SplitSourceName(const F:ansistring; var Typ:char; var Name:ansistring):boolean;
var b:ansistring; i:longint;
begin
  SplitSourceName:=false;
  if not SameText(ExtractFileExt(F),'.txt') then exit;
  b:=ChangeFileExt(ExtractFileName(F),'');
  i:=1; while (i<=length(b)) and (b[i] in ['0'..'9']) do inc(i);
  if (i=1) or (i+2>length(b)) or (b[i]<>'-') or (b[i+2]<>'-') then exit;
  Typ:=b[i+1]; Name:=copy(b,i+3,maxlongint);
  SplitSourceName:=true;
end;
function SourceToFand(const S:ansistring):ansistring;
var t,r:ansistring; i:longint;
begin
  t:=S; if copy(t,1,3)=#$EF#$BB#$BF then delete(t,1,3);
  t:=SUtf8To852(t); r:='';
  for i:=1 to length(t) do
    if t[i]=#10 then begin
      if (i=1) or (t[i-1]<>#13) then r:=r+#13; r:=r+#10 end
    else r:=r+t[i];
  SourceToFand:=r;
end;
function FandToSource(const S:ansistring):ansistring;
var r:ansistring; i:longint;
begin
  r:='';
  for i:=1 to length(S) do
    if (S[i]=#13) and (i<length(S)) and (S[i+1]=#10) then
    else if S[i]=#13 then r:=r+#10
    else r:=r+S[i];
  FandToSource:=U(r);
end;
procedure SourceIn(const Task,Dir:string);
var sr:TSearchRec; names,texts,oldNm,oldDcl:array of ansistring; i,j:longint; t:ansistring;
    typ:char; nm:ansistring; x:LongStrPtr; p:pointer; md:LockMode;
begin
  names:=nil;
  if SysUtils.FindFirst(IncludeTrailingPathDelimiter(Dir)+'*',faAnyFile,sr)=0 then begin
    repeat
      if SplitSourceName(sr.Name,typ,nm) then begin
        SetLength(names,length(names)+1); names[high(names)]:=sr.Name end;
    until SysUtils.FindNext(sr)<>0;
    SysUtils.FindClose(sr) end;
  if length(names)=0 then begin
    Say('no chapter files (NNN-T-Name.txt) in '+Dir); exit end;
  for i:=0 to high(names)-1 do for j:=i+1 to high(names) do
    if names[j]<names[i] then begin t:=names[i]; names[i]:=names[j]; names[j]:=t end;
  SetLength(texts,length(names));             { all of them before the RDB is emptied }
  for i:=0 to high(names) do
    if not FandReadFile(IncludeTrailingPathDelimiter(Dir)+names[i],texts[i]) then begin
      Say('cannot read '+names[i]+'; nothing stored'); exit end;
  IsTestRun:=true;
  CreateOpenChpt(Task,true); Opened:=true;
  if CRdb^.Encrypted then begin
    Say(Task+': the chapters are password-protected; not replaced'); exit end;
  CFile:=Chpt; CRecPtr:=Chpt^.RecPtr;
  { the F chapters' declarations now: the compile converts their data
    files to the new ones (MergeOldNew) }
  oldNm:=nil; oldDcl:=nil;
  for i:=1 to Chpt^.NRecs do begin
    ReadRec(i);
    if TrimRightCh(_ShortS(ChptTyp),' ')='F' then begin
      MarkStore(p); SetLength(oldNm,length(oldNm)+1); SetLength(oldDcl,length(oldDcl)+1);
      oldNm[high(oldNm)]:=UpperCase(TrimRightCh(_ShortS(ChptName),' '));
      oldDcl[high(oldDcl)]:=LongToAnsi(_LongS(ChptTxt)); ReleaseStore(p) end end;
  md:=RewriteF(false);
  for i:=0 to high(names) do begin
    SplitSourceName(names[i],typ,nm);
    if length(nm)>12 then Warn(names[i]+': the name is longer than 12 characters');
    t:=SourceToFand(texts[i]);
    if length(t)>$FFF0 then Warn(names[i]+': longer than a chapter can be, cut');
    MarkStore(p);
    ZeroAllFlds; S_(ChptTyp,typ); S_(ChptName,SUtf8To852(nm)); B_(ChptVerif,false);
    x:=AnsiToLong(t); StoreChptTxt(ChptTxt,x,false);
    if typ='F' then
      for j:=0 to high(oldNm) do if oldNm[j]=UpperCase(SUtf8To852(nm)) then begin
        SetOldDcl(AnsiToLong(oldDcl[j])); break end;
    PutRec;
    ReleaseStore(p);
  end;
  OldLMode(md); SetCompileAll; SaveFiles;
  Say(Task+': '+IStr(length(names))+' chapters from '+Dir);
  if Compiled then Outcome:=0
  else Say('the task does not compile (the chapters are stored)');
end;
procedure SourceOut(const Task,Dir:string);
var i:longint; typ,nm,f:ansistring; x:LongStrPtr; p:pointer; c:longint;
begin
  CreateOpenChpt(Task,false); Opened:=true;
  if CRdb^.Encrypted then begin
    Say(Task+': the chapters are password-protected; not written'); exit end;
  if not ForceDirectories(Dir) then begin Say('cannot create '+Dir); exit end;
  CFile:=Chpt; CRecPtr:=Chpt^.RecPtr; c:=0;
  for i:=1 to Chpt^.NRecs do begin
    MarkStore(p); ReadRec(i);
    typ:=TrimRightCh(_ShortS(ChptTyp),' '); if typ='' then typ:='_';
    nm:=U(TrimRightCh(_ShortS(ChptName),' '));
    f:=Format('%.3d-%s-%s.txt',[i,typ,nm]);
    f:=StringReplace(StringReplace(f,'/','_',[rfReplaceAll]),'\','_',[rfReplaceAll]);
    x:=_LongS(ChptTxt);
    if not FandWriteWhole(IncludeTrailingPathDelimiter(Dir)+f,FandToSource(LongToAnsi(x)),false) then
      Warn('cannot write '+f) else inc(c);
    ReleaseStore(p) end;
  Say(Task+': '+IStr(c)+' chapters to '+Dir);
  if Warnings=0 then Outcome:=0 else Outcome:=2;
end;
function TrimLeftCh(const S:ansistring; C:char):ansistring;
var n:longint;
begin n:=1; while (n<=length(S)) and (S[n]=C) do inc(n); TrimLeftCh:=copy(S,n,maxlongint) end;
procedure OpenCompiled(const Task:string);
begin
  CreateOpenChpt(Task,false); Opened:=true;
  if not Compiled then begin Say('the task does not compile'); GoExit end;
end;
var OutF:file; OutBuf:ansistring; OutLen:longint; OutOk:boolean;
procedure OutFlush;
begin
  if (OutLen>0) and OutOk then begin
    BlockWrite(OutF,OutBuf[1],OutLen); if IOResult<>0 then OutOk:=false end;
  OutLen:=0;
end;
procedure W(const S:ansistring);
var n:longint;
begin
  n:=length(S); if n=0 then exit;
  if OutLen+n>length(OutBuf) then begin
    OutFlush;
    if n>length(OutBuf) then SetLength(OutBuf,n) end;
  move(S[1],OutBuf[OutLen+1],n); inc(OutLen,n);
end;
function Esc(const S:ansistring):ansistring;
var r:ansistring; i:longint; c:char;
begin
  r:='';
  for i:=1 to length(S) do begin
    c:=S[i];
    case c of
      '&': r:=r+'&amp;';
      '<': r:=r+'&lt;';
      '>': r:=r+'&gt;';
      '"': r:=r+'&quot;';
      #13: r:=r+'&#13;';
      #9,#10: r:=r+c;
      #0..#8,#11,#12,#14..#31: r:=r+UniToUtf8($2400+ord(c));
    else r:=r+c end end;
  Esc:=r;
end;
function FldPtr(F:FieldDPtr):PByteArray;
begin FldPtr:=PByteArray(PtrUInt(CRecPtr)+PtrUInt(F^.Displ)) end;
function FixIsNull(F:FieldDPtr):boolean;
var p:PByteArray; i:integer;
begin
  p:=FldPtr(F); FixIsNull:=false;
  if p^[0]<>$80 then exit;
  for i:=1 to F^.NBytes-1 do if p^[i]<>0 then exit;
  FixIsNull:=true;
end;
function AllFF(F:FieldDPtr):boolean;
var p:PByteArray; i:integer;
begin
  p:=FldPtr(F); AllFF:=false;
  for i:=0 to F^.NBytes-1 do if p^[i]<>$FF then exit;
  AllFF:=true;
end;
function FixToText(F:FieldDPtr):ansistring;
var p:PByteArray; v:int64; i:integer; neg:boolean; s,ip,fp:ansistring;
begin
  p:=FldPtr(F); v:=0;
  for i:=0 to F^.NBytes-1 do v:=(v shl 8) or p^[i];
  if (F^.NBytes<8) and (p^[0] and $80<>0) then v:=v-(int64(1) shl (8*F^.NBytes));
  neg:=v<0; if neg then v:=-v;
  str(v,s);
  if F^.M>0 then begin
    while length(s)<=F^.M do s:='0'+s;
    ip:=copy(s,1,length(s)-F^.M); fp:=copy(s,length(s)-F^.M+1,F^.M);
    s:=ip+'.'+fp end;
  if neg then s:='-'+s;
  FixToText:=s;
end;
var FS:TFormatSettings;
function FloatText(R:double; Real48:boolean):ansistring;
var p:integer; s:ansistring; r2:double; a,b:array[0..5] of byte;
begin
  if Real48 then FloatToReal48(R,@a);
  for p:=1 to 17 do begin
    s:=FloatToStrF(R,ffGeneral,p,0,FS);
    if TryStrToFloat(s,r2,FS) then
      if Real48 then begin
        FloatToReal48(r2,@b); if CompareByte(a,b,6)=0 then break end
      else if r2=R then break end;
  FloatText:=s;
end;
function Two(N:longint):ansistring;
begin if N<10 then Two:='0'+IStr(N) else Two:=IStr(N) end;
type TDateKind=(dkDate,dkDateTime,dkTime,dkNumber);
function DateKind(F:FieldDPtr):TDateKind;
var m:string; d,t:boolean;
begin
  m:=FieldDMask(F)^;
  d:=(pos('Y',m)>0) or (pos('M',m)>0);
  t:=(pos('h',m)>0) or (pos('m',m)>0) or (pos('s',m)>0) or (pos('t',m)>0);
  if d and t then DateKind:=dkDateTime
  else if d then DateKind:=dkDate
  else if t and (pos('D',m)=0) then DateKind:=dkTime
  else DateKind:=dkNumber;
end;
function ClockText(L:int64; Tt:boolean):ansistring;
var s:ansistring;
begin
  s:=Two(L div 360000)+':'+Two((L div 6000) mod 60)+':'+Two((L div 100) mod 60);
  if Tt then s:=s+'.'+Two(L mod 100);
  ClockText:=s;
end;
function DateText(F:FieldDPtr; R:double):ansistring;
var k:TDateKind; tot,days,l,u:int64; d,m,y:word; tt:boolean; s:ansistring;
begin
  k:=DateKind(F); tt:=pos('t',FieldDMask(F)^)>0;
  if tt then u:=8640000 else u:=86400;
  case k of
    dkNumber: DateText:=FloatText(R,(CFile^.Typ<>'D') and (F^.NBytes=6));
    dkTime: begin
        s:=''; if R<0 then begin s:='-'; R:=-R end;
        if R<1E-9 then R:=0;
        l:=round(R*u); if not tt then l:=l*100;
        DateText:=s+ClockText(l,tt) end;
  else begin
    tot:=round(R*u); days:=tot div u; l:=tot mod u; if not tt then l:=l*100;
    SplitDate(days,d,m,y);
    s:=Format('%.4d-%.2d-%.2d',[y,m,d]);
    if (k=dkDateTime) or (l<>0) then s:=s+' '+ClockText(l,tt);
    DateText:=s end end;
end;
const RowCol='fand_row';
var Timed:array of FieldDPtr;
function IsTimed(F:FieldDPtr):boolean;
var i:integer;
begin
  IsTimed:=false;
  for i:=0 to high(Timed) do if Timed[i]=F then begin IsTimed:=true; exit end;
end;
function SqlType(F:FieldDPtr):ansistring;
var l:integer; t:ansistring;
begin
  case F^.Typ of
    'A','N': t:='varchar('+IStr(F^.L)+')';
    'F': begin
        if (CFile^.Typ='D') or (F^.NBytes>=8) then begin
          if F^.M=0 then l:=F^.L-1 else l:=F^.L-2;
          if F^.NBytes>=8 then l:=19 end
        else l:=length(IStr((int64(1) shl (8*F^.NBytes-1))-1));
        if l<=F^.M then l:=F^.M+1;
        t:='decimal('+IStr(l)+','+IStr(F^.M)+')' end;
    'R': t:='double';
    'B': t:='tinyint(1)';
    'T': t:='mediumtext';
    'D': case DateKind(F) of
           dkDate: if IsTimed(F) then t:='datetime' else t:='date';
           dkDateTime: t:='datetime';
           dkTime: t:='time';
         else t:='double' end;
  else t:='text' end;
  if (F^.Typ='D') and (DateKind(F) in [dkDateTime,dkTime]) and
     (pos('t',FieldDMask(F)^)>0) then t:=t+'(2)';
  SqlType:=t;
end;
function FandType(F:FieldDPtr):ansistring;
var s:ansistring;
begin
  case F^.Typ of
    'A': begin s:='A,'+IStr(F^.L); if F^.M<>LeftJust then s:=s+'R' end;
    'N': begin s:='N,'+IStr(F^.L); if F^.M=LeftJust then s:=s+'L' end;
    'F': begin
        if F^.M=0 then s:='F,'+IStr(F^.L-1)
        else if F^.Flg and f_Comma<>0 then s:='F,'+IStr(F^.L-F^.M-2)+','+IStr(F^.M)
        else s:='F,'+IStr(F^.L-F^.M-2)+'.'+IStr(F^.M) end;
    'D': s:='D,'''+FieldDMask(F)^+'''';
  else s:=F^.Typ end;
  FandType:='FAND '+s;
end;
function FieldText(F:FieldDPtr; var IsNull:boolean):ansistring;
var s:ansistring; x:LongStrPtr; r:double;
begin
  IsNull:=false; s:='';
  case F^.Typ of
    'A': if (F^.Flg and f_Encryp=0) and AllFF(F) then IsNull:=true
         else begin s:=_ShortS(F);
           if F^.M=LeftJust then s:=TrimRightCh(s,' ') else s:=TrimLeftCh(s,' ') end;
    'N': if AllFF(F) then IsNull:=true else s:=_ShortS(F);
    'F': if CFile^.Typ='D' then s:=FloatText(_R(F),false)
         else if FixIsNull(F) then IsNull:=true
         else s:=FixToText(F);
    'R': if (CFile^.Typ<>'D') and AllFF(F) then IsNull:=true
         else s:=FloatText(_R(F),(CFile^.Typ<>'D') and (F^.NBytes=6));
    'D': begin r:=_R(F); if r=0 then IsNull:=true else s:=DateText(F,r) end;
    'B': if _B(F) then s:='1' else s:='0';
    'T': begin x:=_LongS(F); s:=LongToAnsi(x); ReleaseStore(x) end;
  end;
  FieldText:=s;
end;
function Exportable(FD:FileDPtr):boolean;
begin Exportable:=(FD^.Typ in ['6','8','X','D']) and not FD^.IsSQLFile end;
{$ifdef UNIX}
function realpath(path,resolved:PChar):PChar; cdecl; external 'c';
{$endif}
function Canonical(const Path:ansistring):ansistring;
var p:ansistring;
{$ifdef UNIX} d,n:ansistring; buf:array[0..4095] of char; {$endif}
begin
  p:=ExpandFileName(UnixPath(Path));
  {$ifdef UNIX}
  if (p<>'') and (p[length(p)]='/') then begin d:=p; n:='' end
  else begin d:=ExtractFilePath(p); n:=ExtractFileName(p) end;
  if realpath(PChar(d),@buf[0])<>nil then begin
    d:=IncludeTrailingPathDelimiter(StrPas(@buf[0])); p:=d+n end;
  {$endif}
  Canonical:=p;
end;
function DataPath(FD:FileDPtr):ansistring;
begin CFile:=FD; SetCPathVol; DataPath:=Canonical(CPath) end;
function Within(const Path,Dir:ansistring):boolean;
var d:ansistring;
begin
  Within:=false; if Dir='' then exit;
  d:=IncludeTrailingPathDelimiter(Canonical(IncludeTrailingPathDelimiter(Dir)));
  {$ifdef MSWINDOWS}
  Within:=SameText(copy(Path,1,length(d)),d);
  {$else}
  Within:=copy(Path,1,length(d))=d;
  {$endif}
end;
function NoFileName(const Path:ansistring):boolean;
begin NoFileName:=(Path='') or (Path[length(Path)] in ['/','\']) end;
function SamePath(const A,B:ansistring):boolean;
begin {$ifdef MSWINDOWS}SamePath:=SameText(A,B){$else}SamePath:=A=B{$endif} end;
type TRdbNode=record
       Name:string;
       Parent:integer;
       ChptPath:ansistring;
     end;
var Rdbs:array of TRdbNode;
    CatRdb,CatFile:array of string;
    RootRdb:RdbDPtr;
    TblName:string;
function ChptPathNow:ansistring;
begin CFile:=Chpt; SetCPathVol; ChptPathNow:=Canonical(CPath) end;
function RdbIndex(const N:string):integer;
var i:integer;
begin
  RdbIndex:=-1;
  for i:=0 to high(Rdbs) do
    if SEquUpcase(Rdbs[i].Name,N) then begin RdbIndex:=i; exit end;
end;
function NamesRdb(const N:string):boolean;
var i:integer;
begin
  NamesRdb:=false;
  for i:=0 to high(CatRdb) do
    if SEquUpcase(CatRdb[i],N) then begin NamesRdb:=true; exit end;
end;
function ChptOwner(const Path:ansistring):integer;
var i:integer;
begin
  ChptOwner:=-1;
  for i:=0 to high(Rdbs) do
    if (Rdbs[i].ChptPath<>'') and SamePath(Rdbs[i].ChptPath,Path) then begin
      ChptOwner:=i; exit end;
end;
function TableOf(Idx:integer; FD:FileDPtr):string;
begin if Idx=0 then TableOf:=FD^.Name else TableOf:=Rdbs[Idx].Name+'__'+FD^.Name end;
procedure CloseTo(R:RdbDPtr);
var er:ExitRecord; was:RdbDPtr;
begin
  while (CRdb<>nil) and (CRdb<>R) do begin
    was:=CRdb;
    Move(ExitBuf,er,sizeof(ExitRecord)); ExitBuf.OvrEx:=Ovr; ExitBuf.ExP:=ExitP; ExitBuf.BrkP:=BreakP; ExitBuf.mBP:=MyBP; if SetJmp(ExitBuf.JmpBuf)<>0 then begin GoExitFired:=true; RestoreExit(er) end else begin GoExitFired:=false;
    CloseChpt; RestoreExit(er) end;
    if CRdb=was then CRdb:=was^.ChainBack;
  end;
end;
function OpenRdb(K:integer; Compile:boolean):boolean;
var er:ExitRecord; R:RdbDPtr; ok:boolean;
label 9;
begin
  OpenRdb:=false; R:=CRdb; ok:=false;
  if Rdbs[K].Parent=-2 then exit;
  Move(ExitBuf,er,sizeof(ExitRecord)); ExitBuf.OvrEx:=Ovr; ExitBuf.ExP:=ExitP; ExitBuf.BrkP:=BreakP; ExitBuf.mBP:=MyBP; if SetJmp(ExitBuf.JmpBuf)<>0 then begin GoExitFired:=true; goto 9 end else GoExitFired:=false;
  CreateOpenChpt(Rdbs[K].Name,false);
  ok:=not Compile or Compiled;
9:RestoreExit(er);
  if not ok then begin
    if CRdb=R then Warn(U(Rdbs[K].Name)+': the sub-RDB cannot be opened; its files are left out')
    else Warn(U(Rdbs[K].Name)+': the sub-RDB does not compile; its files are left out');
    Rdbs[K].Parent:=-2; CloseTo(R); exit end;
  OpenRdb:=true;
end;
procedure Discover(Idx:integer);
var i,k:integer; nm:string;
begin
  for i:=0 to high(CatRdb) do
    if SEquUpcase(CatRdb[i],Rdbs[Idx].Name) then begin
      nm:=CatFile[i];
      if IsIdentifStr(nm) and NamesRdb(nm) and (RdbIndex(nm)<0) then begin
        k:=length(Rdbs); SetLength(Rdbs,k+1);
        Rdbs[k].Name:=nm; Rdbs[k].Parent:=Idx; Rdbs[k].ChptPath:='';
        if OpenRdb(k,false) then begin
          Rdbs[k].ChptPath:=ChptPathNow; Discover(k); CloseTo(CRdb^.ChainBack) end end end;
end;
procedure FindRdbs(const Task:string);
var i,n:longint; s:string;
begin
  SetLength(Rdbs,1); Rdbs[0].Name:=Task; Rdbs[0].Parent:=-1;
  Rdbs[0].ChptPath:=ChptPathNow; RootRdb:=CRdb;
  CatRdb:=nil; CatFile:=nil;
  if (CatFD=nil) or (CatFD^.Handle=$FF) then exit;
  n:=CatFD^.NRecs; SetLength(CatRdb,n); SetLength(CatFile,n);
  for i:=1 to n do begin
    CatRdb[i-1]:=RdCatField(i,CatRdbName); CatFile[i-1]:=RdCatField(i,CatFileName) end;
  Discover(0);
  s:='';
  for i:=0 to n-1 do
    if IsIdentifStr(CatRdb[i]) and (RdbIndex(CatRdb[i])<0) and
       (pos('|'+UpperCase(CatRdb[i])+'|',s)=0) then begin
      s:=s+'|'+UpperCase(CatRdb[i])+'|';
      Say('  the catalogue has files of RDB '+U(CatRdb[i])+
          ', which no RDB of the task refers to; they are left out') end;
end;
function KeyStored(K:KeyDPtr):boolean;
var KF:KeyFldDPtr;
begin
  KeyStored:=K^.KFlds<>nil; KF:=K^.KFlds;
  while KF<>nil do begin
    if KF^.FldD^.Flg and f_Stored=0 then KeyStored:=false;
    KF:=KF^.Chain end;
end;
function KeyName(FD:FileDPtr; K:KeyDPtr; N:integer):ansistring;
var kn:ansistring; K2:KeyDPtr; i:integer;
begin
  kn:='';
  if K^.Alias<>nil then kn:=K^.Alias^;
  if (kn='') or (kn='@') then kn:='key'+IStr(N)
  else begin
    K2:=FD^.Keys; i:=1;
    while K2<>K do begin
      if (K2^.Alias<>nil) and SEquUpcase(K2^.Alias^,kn) then begin kn:=kn+IStr(N); break end;
      K2:=K2^.Chain; inc(i) end end;
  KeyName:=kn;
end;
procedure ExportStructure(FD:FileDPtr; NRows:longint);
var F:FieldDPtr; K:KeyDPtr; KF:KeyFldDPtr; n,seq:integer; kn:ansistring;
begin
  W(#9'<table_structure name="'+Esc(U(TblName))+'">'#10);
  W(#9#9'<field Field="'+RowCol+'" Type="int(10) unsigned" Null="" Key="PRI" Extra="" Comment="the record''s place in the FAND file" />'#10);
  F:=FD^.FldD;
  while F<>nil do begin
    if F^.Flg and f_Stored<>0 then
      W(#9#9'<field Field="'+Esc(U(F^.Name))+'" Type="'+SqlType(F)+
        '" Null="YES" Key="" Extra="" Comment="'+Esc(U(FandType(F)))+'" />'#10);
    F:=F^.Chain end;
  W(#9#9'<key Table="'+Esc(U(TblName))+'" Non_unique="0" Key_name="PRIMARY" Seq_in_index="1" Column_name="'+
    RowCol+'" Collation="A" Cardinality="'+IStr(NRows)+'" Sub_part="" Packed="" Null="" Index_type="BTREE" Comment="" Index_comment="" />'#10);
  K:=FD^.Keys; n:=0;
  while K<>nil do begin
    inc(n); kn:=U(KeyName(FD,K,n));
    if KeyStored(K) then KF:=K^.KFlds else KF:=nil; seq:=0;
    while KF<>nil do begin
      inc(seq);
      W(#9#9'<key Table="'+Esc(U(TblName))+'" Non_unique="'+IStr(ord(K^.Duplic))+
        '" Key_name="'+Esc(kn)+'" Seq_in_index="'+IStr(seq)+'" Column_name="'+
        Esc(U(KF^.FldD^.Name))+'" Collation="');
      if KF^.Descend then W('D') else W('A');
      W('" Cardinality="'+IStr(NRows)+'" Sub_part="" Packed="" Null="YES" Index_type="BTREE" Comment="" Index_comment="" />'#10);
      KF:=KF^.Chain end;
    K:=K^.Chain end;
  W(#9#9'<options Name="'+Esc(U(TblName))+'" Rows="'+IStr(NRows)+
    '" Comment="FAND file type '+FD^.Typ+'" />'#10);
  W(#9'</table_structure>'#10);
end;
var SqlOut:boolean;
function SqlName(const S:ansistring):ansistring;
var r:ansistring; i:longint;
begin
  r:=U(S);
  for i:=length(r) downto 1 do if r[i]='`' then insert('`',r,i);
  SqlName:='`'+r+'`';
end;
function SqlStr(const S:ansistring):ansistring;
var r:ansistring; i:longint;
begin
  r:='''';
  for i:=1 to length(S) do
    case S[i] of
      '''': r:=r+'\''';
      '\': r:=r+'\\';
      #0: r:=r+'\0';
      #10: r:=r+'\n';
      #13: r:=r+'\r';
      #26: r:=r+'\Z';
    else r:=r+S[i] end;
  SqlStr:=r+'''';
end;
function SqlBare(F:FieldDPtr):boolean;
begin SqlBare:=(F^.Typ in ['F','R','B']) or ((F^.Typ='D') and (DateKind(F)=dkNumber)) end;
function KeyBytes(F:FieldDPtr):integer;
begin
  case F^.Typ of
    'A','N': KeyBytes:=4*F^.L+2;
    'F': KeyBytes:=(F^.L+1) div 2;
    'B': KeyBytes:=1;
  else KeyBytes:=8 end;
end;
procedure SqlStructure(FD:FileDPtr);
var F:FieldDPtr; K:KeyDPtr; KF:KeyFldDPtr; n,total,fixed,nvar,room:longint;
    cols:ansistring; first:boolean;
begin
  W(#10'DROP TABLE IF EXISTS '+SqlName(TblName)+';'#10);
  W('CREATE TABLE '+SqlName(TblName)+' (');
  W(#10'  `'+RowCol+'` int(10) unsigned NOT NULL COMMENT ''the record''''s place in the FAND file''');
  first:=false; F:=FD^.FldD;
  while F<>nil do begin
    if F^.Flg and f_Stored<>0 then begin
      if not first then W(',');
      W(#10'  '+SqlName(F^.Name)+' '+SqlType(F)+' DEFAULT NULL COMMENT '+
        SqlStr(U(FandType(F))));
      first:=false end;
    F:=F^.Chain end;
  K:=FD^.Keys; n:=0;
  while K<>nil do begin
    inc(n);
    if KeyStored(K) then begin
      total:=0; fixed:=0; nvar:=0; KF:=K^.KFlds;
      while KF<>nil do begin
        inc(total,KeyBytes(KF^.FldD));
        if KF^.FldD^.Typ in ['A','N'] then inc(nvar) else inc(fixed,KeyBytes(KF^.FldD));
        KF:=KF^.Chain end;
      room:=maxint;
      if (total>3072) and (nvar>0) then begin
        room:=((3072-fixed) div nvar - 2) div 4; if room<1 then room:=1 end;
      cols:=''; KF:=K^.KFlds;
      while KF<>nil do begin
        if cols<>'' then cols:=cols+',';
        cols:=cols+SqlName(KF^.FldD^.Name);
        if (KF^.FldD^.Typ in ['A','N']) and (KF^.FldD^.L>room) then
          cols:=cols+'('+IStr(room)+')';
        if KF^.Descend then cols:=cols+' DESC';
        KF:=KF^.Chain end;
      W(','#10'  KEY '+SqlName(KeyName(FD,K,n))+' ('+cols+')') end;
    K:=K^.Chain end;
  W(','#10'  PRIMARY KEY (`'+RowCol+'`)');
  W(#10') ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='+
    SqlStr('FAND file type '+FD^.Typ)+';'#10);
end;
procedure SqlRow(FD:FileDPtr; N:longint);
var F:FieldDPtr; v:ansistring; nul,first:boolean;
begin
  if N mod 200=0 then begin
    if N>0 then W(';'#10);
    W('INSERT INTO '+SqlName(TblName)+' VALUES'#10'(') end
  else W(','#10'(');
  W(IStr(N+1)); first:=false; F:=FD^.FldD;
  while F<>nil do begin
    if F^.Flg and f_Stored<>0 then begin
      if not first then W(',');
      v:=FieldText(F,nul);
      if nul then W('NULL') else if SqlBare(F) then W(v) else W(SqlStr(U(v)));
      first:=false end;
    F:=F^.Chain end;
  W(')');
end;
var TotalRows,TotalFiles:longint;
procedure ExportFile(FD:FileDPtr);
var Scan:XScanPtr; md:LockMode; F:FieldDPtr; p:pointer; v:ansistring; nul,exists:boolean;
    n:longint;
begin
  CFile:=FD; SetCPathVol; exists:=FileExists(UnixPath(CPath));
  Timed:=nil;
  n:=0; if exists then begin
    MarkStore(p); CFile:=FD; CRecPtr:=GetRecSpace; md:=NewLMode(RdMode);
    New(Scan,Init(CFile,nil,nil,true)); Scan^.Reset(nil,false); Scan^.GetRec;
    while not Scan^.EOF do begin
      inc(n); F:=CFile^.FldD;
      while F<>nil do begin
        if (F^.Flg and f_Stored<>0) and (F^.Typ='D') and (DateKind(F)=dkDate) then
          if (round(_R(F)*86400) mod 86400<>0) and not IsTimed(F) then begin
            SetLength(Timed,length(Timed)+1); Timed[high(Timed)]:=F end;
        F:=F^.Chain end;
      Scan^.GetRec end;
    Scan^.Close; OldLMode(md); ClearRecSpace(CRecPtr); ReleaseStore(p) end;
  if SqlOut then SqlStructure(FD) else begin
    ExportStructure(FD,n);
    W(#9'<table_data name="'+Esc(U(TblName))+'">'#10) end;
  n:=0;
  if exists then begin
    MarkStore(p); CFile:=FD; CRecPtr:=GetRecSpace; md:=NewLMode(RdMode);
    New(Scan,Init(CFile,nil,nil,true)); Scan^.Reset(nil,false);
    Scan^.GetRec;
    while not Scan^.EOF do begin
      if SqlOut then SqlRow(FD,n) else begin
      W(#9'<row>'#10#9#9'<field name="'+RowCol+'">'+IStr(n+1)+'</field>'#10);
      F:=CFile^.FldD;
      while F<>nil do begin
        if F^.Flg and f_Stored<>0 then begin
          v:=FieldText(F,nul);
          if nul then W(#9#9'<field name="'+Esc(U(F^.Name))+'" xsi:nil="true" />'#10)
          else W(#9#9'<field name="'+Esc(U(F^.Name))+'">'+Esc(U(v))+'</field>'#10) end;
        F:=F^.Chain end;
      W(#9'</row>'#10) end;
      inc(n); Scan^.GetRec end;
    Scan^.Close; OldLMode(md); ClearRecSpace(CRecPtr); ReleaseStore(p) end;
  if SqlOut then begin if n>0 then W(';'#10) end
  else W(#9'</table_data>'#10);
  CFile:=FD; SetCPathVol;
  if exists then Say('  '+U(TblName)+': '+IStr(n)+' records from '+U(ExpandFileName(UnixPath(CPath))))
  else Say('  '+U(TblName)+': no records, '+U(ExpandFileName(UnixPath(CPath)))+' does not exist');
  inc(TotalFiles); inc(TotalRows,n);
end;
var ExpPaths,ExpTbls:array of ansistring;
procedure ExportRdbFiles(Idx:integer);
var FD:FileDPtr; path:ansistring; i,k,dup:integer;
begin
  FD:=CRdb^.FD^.Chain;
  while FD<>nil do begin
    if Exportable(FD) then begin
      TblName:=TableOf(Idx,FD); path:=DataPath(FD);
      k:=ChptOwner(path); dup:=-1;
      for i:=0 to high(ExpPaths) do if SamePath(ExpPaths[i],path) then dup:=i;
      if NoFileName(path) then
        Say('  '+U(TblName)+': the catalogue gives only the directory '+U(path)+
            ' (the task names the file at run time); left out')
      else if k>=0 then
        Say('  '+U(TblName)+': the chapter file of '+U(Rdbs[k].Name)+', not data; left out')
      else if dup>=0 then
        Say('  '+U(TblName)+': the same file as '+U(ExpTbls[dup])+'; not repeated')
      else begin
        i:=length(ExpPaths); SetLength(ExpPaths,i+1); SetLength(ExpTbls,i+1);
        ExpPaths[i]:=path; ExpTbls[i]:=TblName;
        ExportFile(FD) end end;
    FD:=FD^.Chain end;
end;
procedure ExportTree(Idx:integer);
var k:integer;
begin
  ExportRdbFiles(Idx);
  for k:=1 to high(Rdbs) do
    if Rdbs[k].Parent=Idx then
      if OpenRdb(k,true) then begin ExportTree(k); CloseTo(CRdb^.ChainBack) end;
end;
procedure ExportData(const Task,FileName:string);
begin
  OpenCompiled(Task); FindRdbs(Task); ExpPaths:=nil; ExpTbls:=nil;
  assign(OutF,FileName); rewrite(OutF,1);
  if IOResult<>0 then begin Say('cannot write '+FileName); exit end;
  OutOk:=true; OutLen:=0; SetLength(OutBuf,1 shl 20);
  TotalRows:=0; TotalFiles:=0;
  if SqlOut then
    W('-- the data of FAND task '+U(Task)+#10+
      '/*!40101 SET NAMES utf8mb4 */;'#10'SET FOREIGN_KEY_CHECKS=0;'#10)
  else begin
    W('<?xml version="1.0"?>'#10'<mysqldump xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'#10);
    W('<database name="'+Esc(U(Task))+'">'#10) end;
  ExportTree(0);
  if SqlOut then W(#10'SET FOREIGN_KEY_CHECKS=1;'#10)
  else W('</database>'#10'</mysqldump>'#10);
  OutFlush; close(OutF);
  if (IOResult<>0) or not OutOk then begin Say('cannot write '+FileName); exit end;
  OutBuf:='';
  Say(Task+': '+IStr(TotalFiles)+' files of '+IStr(length(Rdbs))+' RDBs, '+
      IStr(TotalRows)+' records to '+FileName);
  if Warnings=0 then Outcome:=0 else Outcome:=2;
end;
var X:ansistring; XP:longint;
function PosFrom(const Sub:ansistring; From:longint):longint;
var i,n:longint;
begin
  PosFrom:=0; n:=length(Sub); if n=0 then exit;
  for i:=From to length(X)-n+1 do
    if (X[i]=Sub[1]) and (CompareByte(X[i],Sub[1],n)=0) then begin
      PosFrom:=i; exit end;
end;
function Unesc(const S:ansistring):ansistring;
var r,e:ansistring; i,j:longint; c:longint; code:integer;
begin
  r:=''; i:=1;
  while i<=length(S) do
    if S[i]<>'&' then begin r:=r+S[i]; inc(i) end
    else begin
      j:=i+1; while (j<=length(S)) and (S[j]<>';') and (j-i<12) do inc(j);
      e:=copy(S,i+1,j-i-1);
      if e='lt' then r:=r+'<' else if e='gt' then r:=r+'>'
      else if e='amp' then r:=r+'&' else if e='quot' then r:=r+'"'
      else if e='apos' then r:=r+''''
      else if copy(e,1,2)='#x' then begin val('$'+copy(e,3,8),c,code); r:=r+UniToUtf8(c) end
      else if copy(e,1,1)='#' then begin val(copy(e,2,8),c,code); r:=r+UniToUtf8(c) end
      else begin r:=r+'&'; inc(i); continue end;
      i:=j+1 end;
  Unesc:=r;
end;
function ToFand(const S:ansistring; var Lossy:boolean):ansistring;
var r,t:ansistring; i:longint;
begin
  r:=''; i:=1;
  while i<=length(S) do
    if (S[i]=#$E2) and (i+2<=length(S)) and (S[i+1]=#$90) and (S[i+2]>=#$80) and (S[i+2]<=#$9F) then begin
      r:=r+chr(ord(S[i+2])-$80); inc(i,3) end
    else begin r:=r+S[i]; inc(i) end;
  t:=SUtf8To852(r); Lossy:=S852ToUtf8(t)<>r; ToFand:=t;
end;
function NextTag(var Name,Attrs:ansistring; var SelfClose:boolean):boolean;
var i,j:longint; q:char;
begin
  NextTag:=false;
  while true do begin
    i:=XP; while (i<=length(X)) and (X[i]<>'<') do inc(i);
    if i>length(X) then begin XP:=i; exit end;
    if copy(X,i,4)='<!--' then begin
      j:=PosFrom('-->',i); if j=0 then begin XP:=length(X)+1; exit end;
      XP:=j+3; continue end;
    if (copy(X,i,2)='<?') or (copy(X,i,2)='<!') then begin
      j:=i; while (j<=length(X)) and (X[j]<>'>') do inc(j); XP:=j+1; continue end;
    j:=i+1; q:=#0;
    while (j<=length(X)) and ((X[j]<>'>') or (q<>#0)) do begin
      if q<>#0 then begin if X[j]=q then q:=#0 end
      else if X[j] in ['"',''''] then q:=X[j];
      inc(j) end;
    Attrs:=copy(X,i+1,j-i-1); XP:=j+1;
    SelfClose:=(length(Attrs)>0) and (Attrs[length(Attrs)]='/');
    if SelfClose then SetLength(Attrs,length(Attrs)-1);
    j:=1; while (j<=length(Attrs)) and not (Attrs[j] in [' ',#9,#10,#13]) do inc(j);
    Name:=copy(Attrs,1,j-1); Attrs:=copy(Attrs,j,maxlongint);
    NextTag:=true; exit end;
end;
function Attr(const Attrs,Nm:ansistring):ansistring;
var i,j:longint; q:char; s:ansistring;
begin
  Attr:=''; s:=' '+StringReplace(StringReplace(Attrs,#9,' ',[rfReplaceAll]),#10,' ',[rfReplaceAll]);
  i:=pos(' '+Nm+'=',s); if i=0 then exit;
  i:=i+length(Nm)+2; if i>length(s) then exit;
  q:=s[i]; if not (q in ['"','''']) then exit;
  j:=i+1; while (j<=length(s)) and (s[j]<>q) do inc(j);
  Attr:=Unesc(copy(s,i+1,j-i-1));
end;
function FieldContent:ansistring;
var j:longint;
begin
  j:=PosFrom('</field>',XP);
  if j=0 then begin FieldContent:=''; XP:=length(X)+1; exit end;
  FieldContent:=Unesc(copy(X,XP,j-XP)); XP:=j+length('</field>');
end;
procedure SkipPast(const Tag:ansistring);
var j:longint;
begin j:=PosFrom(Tag,XP); if j=0 then XP:=length(X)+1 else XP:=j+length(Tag) end;
function FindFD(R:RdbDPtr; const Name:ansistring):FileDPtr;
var FD:FileDPtr; n:string; lossy:boolean;
begin
  n:=copy(ToFand(Name,lossy),1,255); FD:=R^.FD^.Chain;
  while (FD<>nil) and not (Exportable(FD) and SEquUpcase(FD^.Name,n)) do FD:=FD^.Chain;
  FindFD:=FD;
end;
var FldNames:array of ansistring; FldPtrs:array of FieldDPtr;
function FindFld(FD:FileDPtr; const Name:ansistring):FieldDPtr;
var F:FieldDPtr; n:string; i:longint; lossy:boolean;
begin
  for i:=0 to high(FldNames) do
    if FldNames[i]=Name then begin FindFld:=FldPtrs[i]; exit end;
  n:=copy(ToFand(Name,lossy),1,255); F:=FD^.FldD;
  while (F<>nil) and not ((F^.Flg and f_Stored<>0) and SEquUpcase(F^.Name,n)) do F:=F^.Chain;
  i:=length(FldNames); SetLength(FldNames,i+1); SetLength(FldPtrs,i+1);
  FldNames[i]:=Name; FldPtrs[i]:=F;
  FindFld:=F;
end;
function TextToFix(F:FieldDPtr; const S:ansistring; var V:int64):boolean;
var t,ip,fp:ansistring; i:longint; neg:boolean; code:integer; e:int64;
begin
  TextToFix:=false; t:=Trim(S); neg:=false;
  if copy(t,1,1)='-' then begin neg:=true; delete(t,1,1) end
  else if copy(t,1,1)='+' then delete(t,1,1);
  i:=pos('.',t); if i=0 then i:=pos(',',t);
  if i=0 then begin ip:=t; fp:='' end else begin ip:=copy(t,1,i-1); fp:=copy(t,i+1,maxlongint) end;
  if ip='' then ip:='0';
  for i:=1 to length(ip) do if not (ip[i] in ['0'..'9']) then exit;
  for i:=1 to length(fp) do if not (fp[i] in ['0'..'9']) then exit;
  while length(fp)<F^.M do fp:=fp+'0';
  e:=0; if length(fp)>F^.M then begin
    if fp[F^.M+1]>='5' then e:=1; fp:=copy(fp,1,F^.M) end;
  val(ip+fp,V,code); if code<>0 then exit;
  V:=V+e; if neg then V:=-V;
  if (F^.NBytes<8) and ((V>=(int64(1) shl (8*F^.NBytes-1))) or (V<-(int64(1) shl (8*F^.NBytes-1)))) then exit;
  TextToFix:=true;
end;
procedure PutFix(F:FieldDPtr; V:int64);
var p:PByteArray; i:integer;
begin
  p:=FldPtr(F);
  for i:=F^.NBytes-1 downto 0 do begin p^[i]:=V and $FF; V:=V shr 8 end;
end;
function Digits(const S:ansistring; var I:longint; N:integer; var V:longint):boolean;
var k:integer;
begin
  Digits:=false; V:=0;
  for k:=1 to N do begin
    if (I>length(S)) or not (S[I] in ['0'..'9']) then exit;
    V:=V*10+ord(S[I])-48; inc(I) end;
  Digits:=true;
end;
function ClockValue(const S:ansistring; var I:longint; var L:int64):boolean;
var h,m,sc,t,j:longint;
begin
  ClockValue:=false; j:=I;
  while (j<=length(S)) and (S[j] in ['0'..'9']) do inc(j);
  if (j=I) or (j>length(S)) or (S[j]<>':') then exit;
  val(copy(S,I,j-I),h,sc); I:=j+1;
  if not Digits(S,I,2,m) then exit;
  sc:=0; t:=0;
  if (I<=length(S)) and (S[I]=':') then begin inc(I); if not Digits(S,I,2,sc) then exit end;
  if (I<=length(S)) and (S[I]='.') then begin
    inc(I); j:=I; while (j<=length(S)) and (S[j] in ['0'..'9']) do inc(j);
    t:=StrToIntDef(copy(copy(S,I,j-I)+'00',1,2),0); I:=j end;
  L:=int64(h)*360000+m*6000+sc*100+t;
  ClockValue:=true;
end;
function TextToDate(F:FieldDPtr; const S:ansistring; var R:double):boolean;
var t:ansistring; i:longint; y,m,d:longint; l:int64; neg:boolean;
begin
  TextToDate:=false; t:=Trim(S);
  case DateKind(F) of
    dkNumber: begin R:=StrToFloatDef(t,0,FS); TextToDate:=TryStrToFloat(t,R,FS) end;
    dkTime: begin
        neg:=copy(t,1,1)='-'; if neg then delete(t,1,1);
        i:=1; if not ClockValue(t,i,l) then exit;
        R:=l/8640000; if R=0 then R:=1E-11; if neg then R:=-R;
        TextToDate:=true end;
  else begin
    i:=1; if not Digits(t,i,4,y) then exit;
    if (i>length(t)) or (t[i]<>'-') then exit; inc(i);
    if not Digits(t,i,2,m) then exit;
    if (i>length(t)) or (t[i]<>'-') then exit; inc(i);
    if not Digits(t,i,2,d) then exit;
    if (y=0) and (m=0) and (d=0) then begin R:=0; TextToDate:=true; exit end;
    if (m<1) or (m>12) or (d<1) or (d>31) then exit;
    l:=0;
    if (i<=length(t)) and (t[i] in [' ','T']) then begin
      inc(i); if not ClockValue(t,i,l) then exit end;
    R:=RDate(y,m,d,0,0,0,0)+l/8640000;
    TextToDate:=true end end;
end;
var BadValues,Replaced:longint;
procedure SetField(F:FieldDPtr; const Utf8:ansistring; IsNull:boolean);
var s:ansistring; v:int64; r:double; x:LongStrPtr; ok,lossy:boolean; i:integer;
begin
  s:=ToFand(Utf8,lossy); ok:=true;
  if lossy and not IsNull then begin
    inc(Replaced);
    if Replaced<=20 then Warn(U(CFile^.Name)+'.'+U(F^.Name)+': "'+copy(Utf8,1,60)+
      '" has characters CP852 lacks; stored as "'+copy(U(s),1,60)+'"')
    else if Replaced=21 then Warn('(further values with such characters are not listed)') end;
  case F^.Typ of
    'A': begin if length(s)>F^.L then ok:=false; S_(F,copy(s,1,255)) end;
    'N': if IsNull then FillChar(FldPtr(F)^,F^.NBytes,$FF)
         else begin s:=Trim(s); if length(s)>F^.L then ok:=false;
           for i:=length(s) downto 1 do
             if not (s[i] in ['0'..'?']) then begin ok:=false; delete(s,i,1) end;
           S_(F,copy(s,1,255)) end;
    'F': if IsNull then begin
           if CFile^.Typ<>'D' then begin PutFix(F,0); FldPtr(F)^[0]:=$80 end end
         else if CFile^.Typ='D' then begin
           ok:=TryStrToFloat(Trim(s),r,FS); if ok then begin
             if F^.Flg and f_Comma<>0 then r:=r*Power10[F^.M]; R_(F,r) end end
         else begin ok:=TextToFix(F,s,v); if ok then PutFix(F,v) end;
    'R': if IsNull then begin
           if CFile^.Typ<>'D' then FillChar(FldPtr(F)^,F^.NBytes,$FF) end
         else begin ok:=TryStrToFloat(Trim(s),r,FS); if ok then R_(F,r) end;
    'D': if IsNull or (Trim(s)='') then R_(F,0)
         else begin ok:=TextToDate(F,s,r); if ok then R_(F,r) end;
    'B': begin s:=UpperCase(Trim(s));
        B_(F,(s='1') or (s='TRUE') or (s='A') or (s='Y') or (s='T') or (s='ANO') or (s='YES')) end;
    'T': if not IsNull and (s<>'') then begin
           if length(s)>$FFF0 then ok:=false;
           x:=AnsiToLong(s); LongS_(F,x); ReleaseStore(x) end;
  end;
  if not ok then begin
    inc(BadValues);
    if BadValues<=20 then Warn(U(CFile^.Name)+'.'+U(F^.Name)+': "'+copy(Utf8,1,60)+
      '" does not fit, stored as far as it goes')
    else if BadValues=21 then Warn('(further values that do not fit are not listed)') end;
end;
function MayReplace(FD:FileDPtr; const Tbl:ansistring):boolean;
var path:ansistring; k:integer;
begin
  path:=DataPath(FD); k:=ChptOwner(path);
  if NoFileName(path) then begin
    Warn(Tbl+': the catalogue gives only the directory '+U(path)+'; skipped');
    MayReplace:=false; exit end;
  if k>=0 then begin
    Warn(Tbl+': the chapter file of '+U(Rdbs[k].Name)+', not data; skipped');
    MayReplace:=false; exit end;
  MayReplace:=Within(path,TopRdbDir) or Within(path,TopDataDir) or
    (GetEnvironmentVariable('FAND_IMPORT_OUTSIDE')='1');
  if not Within(path,TopRdbDir) and not Within(path,TopDataDir) then
    if GetEnvironmentVariable('FAND_IMPORT_OUTSIDE')='1' then
      Say('  '+Tbl+': outside the task directory, at '+U(path))
    else Warn(Tbl+': the catalogue places it at '+U(path)+
      ', outside the task directory; skipped (FAND_IMPORT_OUTSIDE=1 allows it)');
end;
var CurIdx:integer;
function SwitchTo(Idx:integer):boolean;
var path:array of integer; k,n:integer;
begin
  SwitchTo:=true; if Idx=CurIdx then exit;
  SaveFiles; CloseTo(RootRdb); CurIdx:=0;
  if Idx=0 then exit;
  n:=0; path:=nil; k:=Idx;
  while k>0 do begin SetLength(path,n+1); path[n]:=k; inc(n); k:=Rdbs[k].Parent end;
  if k<>0 then begin SwitchTo:=false; exit end;
  for k:=n-1 downto 0 do
    if not OpenRdb(path[k],true) then begin
      CloseTo(RootRdb); SwitchTo:=false; exit end;
  CurIdx:=Idx;
end;
function TableFD(const Tbl:ansistring):FileDPtr;
var FD:FileDPtr; p,k:integer; lossy:boolean;
begin
  FD:=FindFD(RootRdb,Tbl); p:=pos('__',Tbl);
  if (FD=nil) and (p>1) then begin
    k:=RdbIndex(copy(ToFand(copy(Tbl,1,p-1),lossy),1,255));
    if k>0 then
      if SwitchTo(k) then FD:=FindFD(CRdb,copy(Tbl,p+2,maxint))
      else begin TableFD:=nil; exit end end;
  TableFD:=FD;
end;
procedure ImportRow(FD:FileDPtr; const Tbl:ansistring; var Unknown:ansistring);
var nm,attrs,fn,v:ansistring; sc,nul:boolean; F:FieldDPtr;
begin
  if not NextTag(nm,attrs,sc) or (nm<>'row') then exit;
  ZeroAllFlds; ClearDeletedFlag;
  if not sc then
    while NextTag(nm,attrs,sc) do begin
      if nm='/row' then break;
      if nm='field' then begin
        fn:=Attr(attrs,'name'); nul:=Attr(attrs,'xsi:nil')='true';
        if sc then v:='' else v:=FieldContent;
        if not SameText(fn,RowCol) then begin
          F:=FindFld(FD,fn);
          if F<>nil then SetField(F,v,nul)
          else if pos('|'+fn+'|',Unknown)=0 then begin
            Unknown:=Unknown+'|'+fn+'|';
            Warn(Tbl+'.'+fn+': the file has no such field; skipped') end end end end;
  PutRec;
end;
var RowAt,RowKey:array of longint;
procedure SortRows(L,R:longint);
var i,j,k,m,t:longint;
begin
  while L<R do begin
    i:=L; j:=R; m:=(L+R) div 2; k:=RowKey[m]; t:=RowAt[m];
    repeat
      while (RowKey[i]<k) or ((RowKey[i]=k) and (RowAt[i]<t)) do inc(i);
      while (RowKey[j]>k) or ((RowKey[j]=k) and (RowAt[j]>t)) do dec(j);
      if i<=j then begin
        m:=RowKey[i]; RowKey[i]:=RowKey[j]; RowKey[j]:=m;
        m:=RowAt[i]; RowAt[i]:=RowAt[j]; RowAt[j]:=m;
        inc(i); dec(j) end;
    until i>j;
    if j-L<R-i then begin SortRows(L,j); L:=i end else begin SortRows(i,R); R:=j end;
  end;
end;
function ImportTable(FD:FileDPtr; const Tbl:ansistring; Stop:longint):longint;
var n,i,re,v,code:longint; keyed,sorted:boolean; unknown,tag:ansistring;
begin
  n:=0; RowAt:=nil; RowKey:=nil; keyed:=true; sorted:=true;
  tag:='<field name="'+RowCol+'">';
  i:=PosFrom('<row',XP);
  while (i>0) and (i<Stop) do begin
    if X[i+4] in ['>','/',' ',#9,#10,#13] then begin
      if length(RowAt)<=n then begin SetLength(RowAt,2*n+16); SetLength(RowKey,2*n+16) end;
      RowAt[n]:=i; RowKey[n]:=-1;
      re:=PosFrom('</row>',i); if (re=0) or (re>Stop) then re:=Stop;
      v:=PosFrom(tag,i);
      if (v>0) and (v<re) then begin
        v:=v+length(tag); code:=v; while (code<re) and (X[code] in ['0'..'9']) do inc(code);
        val(copy(X,v,code-v),RowKey[n],code); if code<>0 then RowKey[n]:=-1 end;
      if RowKey[n]<0 then keyed:=false
      else if (n>0) and (RowKey[n]<RowKey[n-1]) then sorted:=false;
      inc(n) end;
    i:=PosFrom('<row',i+4) end;
  if keyed and not sorted and (n>1) then SortRows(0,n-1);
  unknown:='';
  for i:=0 to n-1 do begin XP:=RowAt[i]; ImportRow(FD,Tbl,unknown) end;
  RowAt:=nil; RowKey:=nil; XP:=Stop;
  ImportTable:=n;
end;
procedure ImportData(const Task,FileName:string);
var nm,attrs,tbl:ansistring; sc:boolean; FD:FileDPtr;
    md:LockMode; p:pointer; rows,files,total,stop:longint;
begin
  OpenCompiled(Task); FindRdbs(Task); CurIdx:=0;
  X:=FandReadWhole(FileName);
  if X='' then begin Say('cannot read '+FileName); exit end;
  XP:=1; files:=0; total:=0; BadValues:=0; Replaced:=0;
  if pos('<mysqldump',X)=0 then begin Say(FileName+' is not a mysqldump --xml document'); exit end;
  while NextTag(nm,attrs,sc) do begin
    if nm='table_structure' then begin
      if not sc then SkipPast('</table_structure>') end
    else if nm='table_data' then begin
      tbl:=Attr(attrs,'name'); FldNames:=nil; FldPtrs:=nil;
      stop:=XP; if not sc then begin
        stop:=PosFrom('</table_data>',XP);
        if stop=0 then begin Say('the document ends inside '+tbl); exit end end;
      FD:=TableFD(tbl);
      if FD=nil then Warn(tbl+': the task declares no such file; skipped')
      else if MayReplace(FD,tbl) then begin
        MarkStore(p); CFile:=FD; CRecPtr:=GetRecSpace; md:=RewriteF(false);
        rows:=ImportTable(FD,tbl,stop);
        CFile:=FD; OldLMode(md); ClearRecSpace(CRecPtr); ReleaseStore(p);
        Say('  '+U(FD^.Name)+': '+IStr(rows)+' records to '+U(DataPath(FD)));
        inc(files); inc(total,rows) end;
      XP:=stop; if not sc then SkipPast('</table_data>') end;
  end;
  X:='';
  SaveFiles; CloseTo(RootRdb);
  Say(Task+': '+IStr(files)+' files, '+IStr(total)+' records from '+FileName);
  if Warnings=0 then Outcome:=0 else Outcome:=2;
end;
procedure Usage;
begin
  Say('usage: fand TASK --source-in DIR | --source-out DIR | --export FILE'+
      ' | --export-sql FILE | --import FILE');
end;
function FandBatchRun(const Task,Op,Arg:string):integer;
var er:ExitRecord;
label 9;
begin
  Outcome:=1; Warnings:=0; Opened:=false; Aborted:=false; BatchMsgCount:=0;
  BatchQuiet:=true;
  FS:=DefaultFormatSettings; FS.DecimalSeparator:='.'; FS.ThousandSeparator:=#0;
  if (Task='--help') or (Arg='') then begin Usage; FandBatchRun:=2; exit end;
  Move(ExitBuf,er,sizeof(ExitRecord)); ExitBuf.OvrEx:=Ovr; ExitBuf.ExP:=ExitP; ExitBuf.BrkP:=BreakP; ExitBuf.mBP:=MyBP; if SetJmp(ExitBuf.JmpBuf)<>0 then begin GoExitFired:=true; Aborted:=true; goto 9 end else GoExitFired:=false;
  if Op='--source-in' then SourceIn(Task,Arg)
  else if Op='--source-out' then SourceOut(Task,Arg)
  else if Op='--export' then begin SqlOut:=false; ExportData(Task,Arg) end
  else if Op='--export-sql' then begin SqlOut:=true; ExportData(Task,Arg) end
  else if Op='--import' then ImportData(Task,Arg)
  else begin Usage; Outcome:=2 end;
9:RestoreExit(er);
  if Aborted then Outcome:=1;
  if Opened then begin
    Opened:=false;
    Move(ExitBuf,er,sizeof(ExitRecord)); ExitBuf.OvrEx:=Ovr; ExitBuf.ExP:=ExitP; ExitBuf.BrkP:=BreakP; ExitBuf.mBP:=MyBP; if SetJmp(ExitBuf.JmpBuf)<>0 then begin GoExitFired:=true; Outcome:=1; RestoreExit(er) end else begin GoExitFired:=false;
    CloseTo(nil); RestoreExit(er) end end;
  if (Outcome=0) and (BatchMsgCount>0) then Outcome:=2;
  FandBatchRun:=Outcome;
end;
end.
