{$mode objfpc}{$H+}
unit fandmdb;
{ The task's files kept in MariaDB: FAND_MDB=user:password@host:port/database.
  Files under FAND_MDB_ROOT (default: the start directory) except the RDB,
  TTT and CAT are rows of fand_file with their bytes in 4 kB rows of
  fand_page. A file absent from the database is loaded from disk when first
  opened; the disk copy is left alone. }
interface
function MdbPath(const Path:ansistring):boolean;
function MdbOpen(const Path:ansistring;Mode:integer;var Err:word):longint;
function MdbRead(F:longint;var Buf;N:longint):longint;
function MdbWrite(F:longint;const Buf;N:longint):longint;
function MdbSeek(F:longint;Dist:int64;Method:integer):int64;
function MdbTrunc(F:longint;N:int64):boolean;
procedure MdbClose(F:longint);
function MdbDate(F:longint):longint;
function MdbDelete(const Path:ansistring):boolean;
function MdbExists(const Path:ansistring):integer;
function MdbRename(const OldPath,NewPath:ansistring):boolean;
function MdbLock(F:longint;Pos,Len:longint):boolean;
procedure MdbUnlock(F:longint;Pos,Len:longint);
function MdbRelock(F:longint;OldPos,OldLen,NewPos,NewLen:longint;
  const Check:array of longint;var Stale:longword):boolean;
{ sends what is held back; called before FAND waits or runs a program }
procedure MdbFlush;
{ the file is no longer read locked: its pages may change under it }
procedure MdbUntrust(F:longint);
implementation
uses sysutils;
{$R-}{$Q-}

{ the few socket calls this needs, from libc or ws2_32: the RTL alone builds it }
const AF_INET=2; SOCK_STREAM=1; IPPROTO_TCP=6; TCP_NODELAY=1;
type TSockAddrIn=packed record
       {$ifdef darwin}Len,Family:byte;{$else}Family:word;{$endif}
       Port:word; Addr:array[0..3] of byte; Zero:array[0..7] of byte end;
{$ifdef MSWINDOWS}
function so_socket(af,typ,proto:longint):PtrInt; stdcall; external 'ws2_32.dll' name 'socket';
function so_connect(s:PtrInt;a:pointer;len:longint):longint; stdcall; external 'ws2_32.dll' name 'connect';
function so_send(s:PtrInt;const buf;len,flags:longint):longint; stdcall; external 'ws2_32.dll' name 'send';
function so_recv(s:PtrInt;var buf;len,flags:longint):longint; stdcall; external 'ws2_32.dll' name 'recv';
function so_setopt(s:PtrInt;level,opt:longint;const val;len:longint):longint; stdcall; external 'ws2_32.dll' name 'setsockopt';
function so_close(s:PtrInt):longint; stdcall; external 'ws2_32.dll' name 'closesocket';
function WSAStartup(ver:word;var data):longint; stdcall; external 'ws2_32.dll' name 'WSAStartup';
const SendFlags=0;
{$else}
function so_socket(af,typ,proto:longint):longint; cdecl; external 'c' name 'socket';
function so_connect(s:longint;a:pointer;len:longint):longint; cdecl; external 'c' name 'connect';
function so_send(s:longint;const buf;len:PtrUInt;flags:longint):PtrInt; cdecl; external 'c' name 'send';
function so_recv(s:longint;var buf;len:PtrUInt;flags:longint):PtrInt; cdecl; external 'c' name 'recv';
function so_setopt(s,level,opt:longint;const val;len:longint):longint; cdecl; external 'c' name 'setsockopt';
function so_close(s:longint):longint; cdecl; external 'c' name 'close';
{ a write to a connection the server closed must not kill the process }
const SendFlags={$ifdef linux}$4000{MSG_NOSIGNAL}{$else}0{$endif};
{$endif}

{ SHA-1, for the password exchange }
function Sha1(const S:ansistring):ansistring;
var h:array[0..4] of longword; w:array[0..79] of longword;
    a,b,c,d,e,f,k,t:longword; m:ansistring; i,j:longint; bits:qword;
  function rol(x:longword;n:byte):longword; begin rol:=(x shl n) or (x shr (32-n)) end;
begin
  h[0]:=$67452301; h[1]:=$EFCDAB89; h[2]:=$98BADCFE; h[3]:=$10325476; h[4]:=$C3D2E1F0;
  bits:=qword(length(S))*8; m:=S+#$80;
  while length(m) mod 64<>56 do m:=m+#0;
  for i:=7 downto 0 do m:=m+chr((bits shr (8*i)) and $FF);
  j:=1;
  while j<length(m) do begin
    for i:=0 to 15 do
      w[i]:=(longword(ord(m[j+4*i])) shl 24) or (longword(ord(m[j+4*i+1])) shl 16) or
            (longword(ord(m[j+4*i+2])) shl 8) or longword(ord(m[j+4*i+3]));
    for i:=16 to 79 do w[i]:=rol(w[i-3] xor w[i-8] xor w[i-14] xor w[i-16],1);
    a:=h[0]; b:=h[1]; c:=h[2]; d:=h[3]; e:=h[4];
    for i:=0 to 79 do begin
      if i<20 then begin f:=(b and c) or (not b and d); k:=$5A827999 end
      else if i<40 then begin f:=b xor c xor d; k:=$6ED9EBA1 end
      else if i<60 then begin f:=(b and c) or (b and d) or (c and d); k:=$8F1BBCDC end
      else begin f:=b xor c xor d; k:=$CA62C1D6 end;
      t:=rol(a,5)+f+e+k+w[i]; e:=d; d:=c; c:=rol(b,30); b:=a; a:=t end;
    inc(h[0],a); inc(h[1],b); inc(h[2],c); inc(h[3],d); inc(h[4],e);
    inc(j,64) end;
  SetLength(Sha1,20);
  for i:=0 to 19 do Sha1[i+1]:=chr((h[i div 4] shr (24-8*(i mod 4))) and $FF);
end;

const PgSize=4096;
type TRows=array of array of ansistring;
     { Ver: the change count the cache of this file was read at, -1 unknown }
     { Trusted: checked on being read locked and still read locked, so its page
       copies are the server's }
     TVF=record Id,Pos,Size,Ver,Gen:int64; Used,Trusted:boolean end;
var
  Sock:PtrInt=-1; Seq:byte;
  InBuf:ansistring; InPos:longint=1;
  Tried:boolean=false; Enabled:boolean=false; Trace:boolean=false;
  Conn,Root,LastErr,DbName:ansistring;
  LastId:int64;
  VF:array of TVF;
  NQuery,NSent,NRecv,NConflict:int64; QTime:double;
  { page writes not sent yet: they go ahead of the next statement, in its round trip }
  Pending:ansistring;
  { the pages as the server has them, so that a write sends only what changed; a
    file's copies belong to its generation Gen, renewed when they may be stale }
  Shadow:array of record Gen,Pg:int64; Data:ansistring end;
  NShadow:longint; NextGen:int64=1;
const ShCap=16384;
function ShFind(Gen,Pg:int64;Add:boolean):longint;
var i:longint;
begin
  if length(Shadow)=0 then SetLength(Shadow,ShCap);
  if Add and (NShadow>ShCap*3 div 4) then begin
    Shadow:=nil; SetLength(Shadow,ShCap); NShadow:=0 end;
  i:=longint((qword(Gen)*1000003+qword(Pg)*7919) mod ShCap);
  while Shadow[i].Gen<>0 do begin
    if (Shadow[i].Gen=Gen) and (Shadow[i].Pg=Pg) then exit(i);
    i:=(i+1) mod ShCap end;
  if not Add then exit(-1);
  Shadow[i].Gen:=Gen; Shadow[i].Pg:=Pg; inc(NShadow); ShFind:=i;
end;
function NewGen:int64;
begin NewGen:=NextGen; inc(NextGen) end;

procedure Die(const S:ansistring);
begin writeln(StdErr,'fand: MariaDB: ',S); halt(1) end;

{ --- the client protocol --- }

function RawRecv(var B;N:longint):boolean;
var got,r:longint; p:PByte;
begin
  p:=@B; got:=0; RawRecv:=false;
  while got<N do begin
    if InPos>length(InBuf) then begin
      SetLength(InBuf,65536); r:=so_recv(Sock,InBuf[1],65536,0);
      if r<=0 then begin InBuf:=''; InPos:=1; exit end;
      SetLength(InBuf,r); InPos:=1; inc(NRecv,r) end;
    r:=length(InBuf)-InPos+1; if r>N-got then r:=N-got;
    move(InBuf[InPos],p[got],r); inc(InPos,r); inc(got,r) end;
  RawRecv:=true;
end;
function ReadPacket(out P:ansistring):boolean;
var h:array[0..3] of byte; len:longint; part:ansistring;
begin
  P:=''; ReadPacket:=false;
  repeat
    if not RawRecv(h,4) then exit;
    len:=h[0] or (h[1] shl 8) or (h[2] shl 16); Seq:=h[3]+1;
    SetLength(part,len); if (len>0) and not RawRecv(part[1],len) then exit;
    P:=P+part;
  until len<$FFFFFF;
  ReadPacket:=true;
end;
function SendPacket(const P:ansistring):boolean;
var s:ansistring; len,off,r:longint;
begin
  SendPacket:=false; len:=length(P); if len>=$FFFFFF then exit;
  s:=chr(len and $FF)+chr((len shr 8) and $FF)+chr(len shr 16)+chr(Seq)+P; inc(Seq);
  off:=1;
  while off<=length(s) do begin
    r:=so_send(Sock,s[off],length(s)-off+1,SendFlags); if r<=0 then exit; inc(off,r) end;
  inc(NSent,length(s)); SendPacket:=true;
end;
function LenEnc(const P:ansistring;var i:longint):int64;
var c:byte; k:integer;
begin
  c:=ord(P[i]); inc(i);
  case c of
    $FB:LenEnc:=-1;
    $FC:begin LenEnc:=ord(P[i]) or (ord(P[i+1]) shl 8); inc(i,2) end;
    $FD:begin LenEnc:=ord(P[i]) or (ord(P[i+1]) shl 8) or (ord(P[i+2]) shl 16); inc(i,3) end;
    $FE:begin LenEnc:=0; for k:=7 downto 0 do LenEnc:=(LenEnc shl 8) or ord(P[i+k]); inc(i,8) end;
  else LenEnc:=c end;
end;
function ErrText(const P:ansistring):ansistring;
var i:longint;
begin
  i:=4; if (length(P)>=4) and (P[4]='#') then i:=10;
  ErrText:=IntToStr(ord(P[2]) or (ord(P[3]) shl 8))+' '+copy(P,i,maxint);
end;
function LE4(x:longword):ansistring;
begin LE4:=chr(x and $FF)+chr((x shr 8) and $FF)+chr((x shr 16) and $FF)+chr(x shr 24) end;
function NativeToken(const Pw,Scr:ansistring):ansistring;
var h1,h3,s:ansistring; i:integer;
begin
  if Pw='' then exit('');
  h1:=Sha1(Pw); h3:=Sha1(copy(Scr,1,20)+Sha1(h1));
  SetLength(s,20); for i:=1 to 20 do s[i]:=chr(ord(h1[i]) xor ord(h3[i]));
  NativeToken:=s;
end;
function Connect:boolean;
var user,pw,host,db,s,g,scr,plugin,tok:ansistring; port,i,k,n:longint;
    addr:TSockAddrIn; one:longint; ip:array[0..3] of longint;
    {$ifdef MSWINDOWS} wsa:array[0..511] of byte; {$endif}
begin
  Connect:=false; s:=Conn;
  i:=pos('@',s); if i=0 then begin LastErr:='FAND_MDB is user:password@host:port/database'; exit end;
  user:=copy(s,1,i-1); delete(s,1,i);
  k:=pos(':',user); if k>0 then begin pw:=copy(user,k+1,maxint); user:=copy(user,1,k-1) end else pw:='';
  i:=pos('/',s); if i>0 then begin db:=copy(s,i+1,maxint); s:=copy(s,1,i-1) end else db:='';
  i:=pos(':',s); if i>0 then begin port:=StrToIntDef(copy(s,i+1,maxint),3306); host:=copy(s,1,i-1) end
  else begin port:=3306; host:=s end;
  if (host='') or SameText(host,'localhost') then host:='127.0.0.1';
  DbName:=copy(db,1,32);
  FillChar(addr,sizeof(addr),0);
  s:=host+'.'; for i:=0 to 3 do begin
    k:=pos('.',s); ip[i]:=StrToIntDef(copy(s,1,k-1),-1); delete(s,1,k);
    if (ip[i]<0) or (ip[i]>255) then begin LastErr:='the host must be an IPv4 address: '+host; exit end;
    addr.Addr[i]:=ip[i] end;
  if s<>'' then begin LastErr:='the host must be an IPv4 address: '+host; exit end;
  {$ifdef darwin} addr.Len:=sizeof(addr); {$endif}
  addr.Family:=AF_INET; addr.Port:=((port and $FF) shl 8) or ((port shr 8) and $FF);
  {$ifdef MSWINDOWS} WSAStartup($0202,wsa); {$endif}
  Sock:=so_socket(AF_INET,SOCK_STREAM,0);
  if Sock<0 then begin LastErr:='no socket'; exit end;
  if so_connect(Sock,@addr,sizeof(addr))<>0 then begin
    LastErr:='cannot connect to '+host+':'+IntToStr(port); so_close(Sock); Sock:=-1; exit end;
  one:=1; so_setopt(Sock,IPPROTO_TCP,TCP_NODELAY,one,sizeof(one));
  {$ifdef darwin} so_setopt(Sock,$FFFF{SOL_SOCKET},$1022{SO_NOSIGPIPE},one,sizeof(one)); {$endif}
  InBuf:=''; InPos:=1; Seq:=0;
  if not ReadPacket(g) then begin LastErr:='no greeting'; exit end;
  if g[1]=#$FF then begin LastErr:=ErrText(g); exit end;
  i:=2; while (i<=length(g)) and (g[i]<>#0) do inc(i);
  inc(i,1+4); scr:=copy(g,i,8); inc(i,8+1+2+1+2+2);
  n:=ord(g[i]); inc(i,1+10);
  if n<21 then n:=21; scr:=scr+copy(g,i,12); inc(i,n-8);
  plugin:=''; while (i<=length(g)) and (g[i]<>#0) do begin plugin:=plugin+g[i]; inc(i) end;
  tok:=NativeToken(pw,scr);
  s:=LE4($1 or $4 or $8 or $200 or $2000 or $8000 or $10000 or $20000 or $80000)
     +LE4($1000000)+chr(63)+StringOfChar(#0,23)+user+#0+chr(length(tok))+tok
     +db+#0+'mysql_native_password'#0;
  if not SendPacket(s) or not ReadPacket(g) then begin LastErr:='handshake'; exit end;
  if g[1]=#$FE then begin
    i:=2; plugin:=''; while (i<=length(g)) and (g[i]<>#0) do begin plugin:=plugin+g[i]; inc(i) end;
    if plugin<>'mysql_native_password' then begin LastErr:='unsupported authentication '+plugin; exit end;
    if not SendPacket(NativeToken(pw,copy(g,i+1,20))) or not ReadPacket(g) then begin
      LastErr:='handshake'; exit end end;
  if g[1]<>#0 then begin LastErr:=ErrText(g); exit end;
  Connect:=true;
end;
function Query1(const SQL:ansistring;var Rows:TRows):integer;
{ 1 ok, 0 SQL error, -1 connection lost }
var P:ansistring; ncol,i,k,n:longint; more:boolean; st:word; r:array of ansistring;
begin
  Query1:=-1; Rows:=nil; Seq:=0;
  if (Sock<0) or not SendPacket(#3+SQL) then exit;
  repeat
    more:=false;
    if not ReadPacket(P) or (P='') then exit;
    if P[1]=#0 then begin
      i:=2; LenEnc(P,i); LastId:=LenEnc(P,i);
      st:=ord(P[i]) or (ord(P[i+1]) shl 8); more:=(st and 8)<>0 end
    else if P[1]=#$FF then begin LastErr:=ErrText(P); Query1:=0; exit end
    else begin
      i:=1; ncol:=LenEnc(P,i);
      for k:=1 to ncol+1 do if not ReadPacket(P) then exit;
      Rows:=nil;
      while true do begin
        if not ReadPacket(P) or (P='') then exit;
        if (P[1]=#$FE) and (length(P)<9) then begin
          st:=ord(P[4]) or (ord(P[5]) shl 8); more:=(st and 8)<>0; break end;
        if P[1]=#$FF then begin LastErr:=ErrText(P); Query1:=0; exit end;
        SetLength(r,ncol); i:=1;
        for k:=0 to ncol-1 do begin
          n:=LenEnc(P,i); if n<0 then r[k]:='' else begin r[k]:=copy(P,i,n); inc(i,n) end end;
        SetLength(Rows,length(Rows)+1); Rows[high(Rows)]:=copy(r,0,ncol) end end;
  until not more;
  Query1:=1;
end;
function Query(const SQL:ansistring;var Rows:TRows):boolean;
var t:TDateTime; r:integer; q:ansistring;
begin
  inc(NQuery); t:=Now; q:=SQL;
  { the held-back writes commit together, ahead of the statement }
  if Pending<>'' then begin q:='START TRANSACTION;'+Pending+'COMMIT;'+SQL; Pending:='' end;
  r:=Query1(q,Rows);
  if r<0 then begin
    if Sock>=0 then so_close(Sock); Sock:=-1;
    if not Connect then Die(LastErr);
    r:=Query1(q,Rows) end;
  if r<0 then Die('connection lost');
  QTime:=QTime+(Now-t)*86400;
  if Trace then writeln(StdErr,'mdb: ',copy(q,1,120));
  if r=0 then Die(LastErr+' in '+copy(q,1,200));
  Query:=true;
end;
procedure Exec(const SQL:ansistring);
var rows:TRows;
begin Query(SQL,rows) end;
procedure Defer(const SQL:ansistring);
begin
  Pending:=Pending+SQL+';';
  if length(Pending)>4000000 then Exec('DO 0');
end;
function Hex(const B;N:longint):ansistring;
const D:array[0..15] of char='0123456789ABCDEF';
var i:longint; p:PByte;
begin
  if N<=0 then exit('''''');
  SetLength(Hex,N*2+3); Hex[1]:='X'; Hex[2]:=''''; p:=@B;
  for i:=0 to N-1 do begin Hex[3+2*i]:=D[p[i] shr 4]; Hex[4+2*i]:=D[p[i] and 15] end;
  Hex[N*2+3]:='''';
end;
function HexS(const S:ansistring):ansistring;
begin if S='' then HexS:='''''' else HexS:=Hex(S[1],length(S)) end;
function I2S(x:int64):ansistring;
begin I2S:=IntToStr(x) end;

{ --- which files --- }

{$ifdef UNIX}
function realpath(p,r:PChar):PChar; cdecl; external 'c' name 'realpath';
{$endif}
function Canon(const P:ansistring):ansistring;
var d,n:ansistring; {$ifdef UNIX}buf:array[0..4095] of char;{$endif}
begin
  d:=ExtractFilePath(ExpandFileName(P)); n:=ExtractFileName(P);
{$ifdef UNIX}
  if realpath(PChar(d),@buf[0])<>nil then d:=IncludeTrailingPathDelimiter(StrPas(@buf[0]));
{$endif}
  Canon:=d+n;
end;
function Init:boolean;
begin
  if not Tried then begin
    Tried:=true; Conn:=GetEnvironmentVariable('FAND_MDB');
    if Conn<>'' then begin
      Trace:=GetEnvironmentVariable('FAND_MDB_TRACE')<>'';
      Root:=GetEnvironmentVariable('FAND_MDB_ROOT'); if Root='' then Root:=GetCurrentDir;
      Root:=Canon(IncludeTrailingPathDelimiter(Root));
      if not Connect then Die(LastErr);
      Exec('CREATE TABLE IF NOT EXISTS fand_file(id INT AUTO_INCREMENT PRIMARY KEY,'+
           'path VARBINARY(255) NOT NULL UNIQUE,size BIGINT NOT NULL DEFAULT 0,'+
           'mtime BIGINT NOT NULL DEFAULT 0,deleted TINYINT NOT NULL DEFAULT 0,'+
           'ver BIGINT NOT NULL DEFAULT 0) ENGINE=InnoDB');
      { ver counts the changes of a file: a cache read at the same count is still good }
      Exec('ALTER TABLE fand_file ADD COLUMN IF NOT EXISTS ver BIGINT NOT NULL DEFAULT 0');
      Exec('CREATE TABLE IF NOT EXISTS fand_page(file INT NOT NULL,pg INT NOT NULL,'+
           'data BLOB NOT NULL,PRIMARY KEY(file,pg)) ENGINE=InnoDB');
      Exec('CREATE TABLE IF NOT EXISTS fand_lock(file INT NOT NULL,pos BIGINT NOT NULL,'+
           'len INT NOT NULL,conn BIGINT NOT NULL,KEY(file,pos)) ENGINE=MEMORY');
      { a range is granted when no live connection holds an overlapping one }
      Exec('CREATE PROCEDURE IF NOT EXISTS fand_trylock(f INT,p BIGINT,l INT) BEGIN '+
           'DECLARE ok INT DEFAULT 0; DECLARE m VARCHAR(64) DEFAULT CONCAT(''fand:'',DATABASE(),'':'',f); '+
           'IF GET_LOCK(m,10) THEN '+
             'IF EXISTS(SELECT 1 FROM fand_lock WHERE file=f AND pos<p+l AND p<pos+len AND conn<>CONNECTION_ID()) THEN '+
               'DELETE FROM fand_lock WHERE file=f AND conn NOT IN (SELECT id FROM information_schema.PROCESSLIST); END IF; '+
             'IF NOT EXISTS(SELECT 1 FROM fand_lock WHERE file=f AND pos<p+l AND p<pos+len AND conn<>CONNECTION_ID()) THEN '+
               'INSERT INTO fand_lock VALUES(f,p,l,CONNECTION_ID()); SET ok=1; END IF; '+
             'DO RELEASE_LOCK(m); END IF; '+
           'SELECT ok; END');
      { a lock mode change: the new range for the old one, or nothing when the new one is taken }
      Exec('CREATE PROCEDURE IF NOT EXISTS fand_mode(f INT,op BIGINT,ol INT,np BIGINT,nl INT,ids VARCHAR(255)) BEGIN '+
           'DECLARE ok INT DEFAULT 0; DECLARE m VARCHAR(64) DEFAULT CONCAT(''fand:'',DATABASE(),'':'',f); '+
           'IF GET_LOCK(m,10) THEN '+
             'IF EXISTS(SELECT 1 FROM fand_lock WHERE file=f AND pos<np+nl AND np<pos+len AND conn<>CONNECTION_ID()) THEN '+
               'DELETE FROM fand_lock WHERE file=f AND conn NOT IN (SELECT id FROM information_schema.PROCESSLIST); END IF; '+
             'IF NOT EXISTS(SELECT 1 FROM fand_lock WHERE file=f AND pos<np+nl AND np<pos+len AND conn<>CONNECTION_ID()) THEN '+
               'IF ol>0 THEN DELETE FROM fand_lock WHERE file=f AND pos=op AND len=ol AND conn=CONNECTION_ID() LIMIT 1; END IF; '+
               'INSERT INTO fand_lock VALUES(f,np,nl,CONNECTION_ID()); SET ok=1; END IF; '+
             'DO RELEASE_LOCK(m); END IF; '+
           'SELECT ok,(SELECT GROUP_CONCAT(id,'':'',ver,'':'',size) FROM fand_file WHERE FIND_IN_SET(id,ids)); END');
      Enabled:=true end end;
  Init:=Enabled;
end;
function Key(const Path:ansistring):ansistring;
var c,e,n:ansistring;
begin
  Key:=''; if not Init then exit;
  c:=Canon(Path);
  if (length(c)<=length(Root)) or (copy(c,1,length(Root))<>Root) then exit;
  n:=UpperCase(ExtractFileName(c)); e:=ExtractFileExt(n);
  if (e='.RDB') or (e='.TTT') or (e='.CAT') or (copy(n,1,8)='FANDWORK') then exit;
  Key:=UpperCase(copy(c,length(Root)+1,maxint));
end;
function MdbPath(const Path:ansistring):boolean;
begin MdbPath:=Key(Path)<>'' end;

{ --- files --- }

function Import(const K,Path:ansistring;Force:boolean):int64;
{ the disk file as file K, in one transaction; sessions loading the same file take
  turns, and without Force one that finds it loaded meanwhile leaves it alone }
var d,sql,m:ansistring; id,n,pg,off:int64; h:THandle; rows:TRows;
begin
  m:='CONCAT(''fand-load:'',MD5(CONCAT(DATABASE(),'+HexS(K)+')))';
  Query('SELECT GET_LOCK('+m+',60)',rows);
  if not Force then begin
    Query('SELECT id FROM fand_file WHERE path='+HexS(K),rows);
    if length(rows)=1 then begin
      Exec('DO RELEASE_LOCK('+m+')'); Import:=StrToInt64(rows[0][0]); exit end end;
  d:=''; h:=FileOpen(Path,fmOpenRead or fmShareDenyNone);
  if h<>THandle(-1) then begin
    SetLength(d,FileSeek(h,0,2)); FileSeek(h,0,0);
    if d<>'' then SetLength(d,FileRead(h,d[1],length(d))); FileClose(h) end;
  Exec('START TRANSACTION');
  Exec('INSERT INTO fand_file(path,size,mtime) VALUES('+HexS(K)+','+I2S(length(d))+','+
       I2S(FileAge(Path))+') ON DUPLICATE KEY UPDATE size=VALUES(size),mtime=VALUES(mtime),deleted=0,ver=ver+1,id=LAST_INSERT_ID(id)');
  id:=LastId; Exec('DELETE FROM fand_page WHERE file='+I2S(id));
  n:=(length(d)+PgSize-1) div PgSize; d:=d+StringOfChar(#0,n*PgSize-length(d));
  pg:=0; sql:='';
  while pg<n do begin
    off:=pg*PgSize+1;
    if sql<>'' then sql:=sql+',';
    sql:=sql+'('+I2S(id)+','+I2S(pg)+','+Hex(d[off],PgSize)+')'; inc(pg);
    if (pg mod 64=0) or (pg=n) then begin Exec('INSERT INTO fand_page VALUES'+sql); sql:='' end end;
  Exec('COMMIT'); Exec('DO RELEASE_LOCK('+m+')');
  Import:=id;
end;
function Slot:longint;
var i:longint;
begin
  for i:=0 to high(VF) do if not VF[i].Used then exit(i);
  SetLength(VF,length(VF)+1); Slot:=high(VF);
end;
function MdbOpen(const Path:ansistring;Mode:integer;var Err:word):longint;
{ Mode as FileOpenMode: 0 new, 1 old, 2 overwrite, 3 old or new }
var k:ansistring; rows:TRows; id,size:int64; exists:boolean; f:longint;
begin
  MdbOpen:=-1; Err:=0; k:=Key(Path); id:=0; size:=0;
  Query('SELECT id,size,deleted FROM fand_file WHERE path='+HexS(k),rows);
  if length(rows)=1 then begin
    id:=StrToInt64(rows[0][0]); size:=StrToInt64(rows[0][1]); exists:=rows[0][2]='0' end
  else if FileExists(Path) then begin
    id:=Import(k,Path,false); Query('SELECT size,deleted FROM fand_file WHERE id='+I2S(id),rows);
    size:=StrToInt64(rows[0][0]); exists:=rows[0][1]='0' end
  else exists:=false;
  if (Mode=0) and exists then begin Err:=80; exit end;
  if (Mode=1) and not exists then begin Err:=2; exit end;
  if not exists or (Mode=2) then begin
    if id=0 then begin
      Exec('INSERT INTO fand_file(path,mtime) VALUES('+HexS(k)+',UNIX_TIMESTAMP()) '+
           'ON DUPLICATE KEY UPDATE id=LAST_INSERT_ID(id)'); id:=LastId end
    else Exec('DELETE FROM fand_page WHERE file='+I2S(id)+
              ';UPDATE fand_file SET size=0,deleted=0,ver=ver+1,mtime=UNIX_TIMESTAMP() WHERE id='+I2S(id));
    size:=0 end;
  f:=Slot; VF[f].Id:=id; VF[f].Pos:=0; VF[f].Size:=size; VF[f].Ver:=-1; VF[f].Gen:=NewGen;
  VF[f].Used:=true; VF[f].Trusted:=false;
  MdbOpen:=f;
end;
const ReadAhead=16;
function MdbRead(F:longint;var Buf;N:longint):longint;
var rows:TRows; p0,p1,pe,st,a,b,pg:int64; i,k:longint; d:ansistring; dst:PByte; all:boolean;
begin
  with VF[F] do begin
    MdbRead:=0; if N<=0 then exit;
    p0:=Pos div PgSize; p1:=(Pos+N-1) div PgSize;
    if Trusted then begin
      { nobody can have changed it: the copies, when they are all there }
      if Pos>=Size then exit;
      if N>Size-Pos then N:=Size-Pos;
      p1:=(Pos+N-1) div PgSize; all:=true; pg:=p0;
      while all and (pg<=p1) do begin all:=ShFind(Gen,pg,false)>=0; inc(pg) end;
      if all then begin
        dst:=@Buf;
        for pg:=p0 to p1 do begin
          d:=Shadow[ShFind(Gen,pg,false)].Data; st:=pg*PgSize;
          a:=st; if a<Pos then a:=Pos;
          b:=st+PgSize; if b>Pos+N then b:=Pos+N;
          move(d[a-st+1],dst[a-Pos],b-a) end;
        inc(Pos,N); MdbRead:=N; exit end end;
    pe:=p1; if Trusted and (pe<p0+ReadAhead-1) then pe:=p0+ReadAhead-1;
    Query('SELECT -1,size FROM fand_file WHERE id='+I2S(Id)+
          ' UNION ALL SELECT pg,data FROM fand_page WHERE file='+I2S(Id)+' AND pg BETWEEN '+
          I2S(p0)+' AND '+I2S(pe),rows);
    if (length(rows)>0) and (rows[0][0]='-1') then Size:=StrToInt64(rows[0][1]);
    if Pos>=Size then exit;
    if N>Size-Pos then N:=Size-Pos;
    dst:=@Buf; FillChar(Buf,N,0);
    for i:=0 to high(rows) do if rows[i][0]<>'-1' then begin
      d:=rows[i][1]; st:=StrToInt64(rows[i][0])*PgSize;
      if length(d)=PgSize then begin k:=ShFind(Gen,st div PgSize,true); Shadow[k].Data:=d end;
      a:=st; if a<Pos then a:=Pos;
      b:=st+length(d); if b>Pos+N then b:=Pos+N;
      if b>a then move(d[a-st+1],dst[a-Pos],b-a) end;
    inc(Pos,N); MdbRead:=N;
  end;
end;
function MdbWrite(F:longint;const Buf;N:longint):longint;
var sql,sid,e:ansistring; p,pg,off,len,left,a,b,c:int64; src:PByte; k:longint;
begin
  with VF[F] do begin
    MdbWrite:=N; if N<=0 then exit;
    sid:=I2S(Id); sql:=''; p:=Pos; left:=N; src:=@Buf;
    while left>0 do begin
      pg:=p div PgSize; off:=p mod PgSize; len:=PgSize-off; if len>left then len:=left;
      k:=ShFind(Gen,pg,false);
      if (len=PgSize) and (k>=0) then begin
        { the server has the page as Shadow: send the changed runs (those closer than
          16 bytes as one), or nothing }
        e:='data'; a:=0;
        while a<PgSize do begin
          while (a<PgSize) and (src[a]=ord(Shadow[k].Data[a+1])) do inc(a);
          if a=PgSize then break;
          b:=a; c:=a;
          while (c<PgSize) and (c-b<=16) do begin
            if src[c]<>ord(Shadow[k].Data[c+1]) then b:=c; inc(c) end;
          e:='INSERT('+e+','+I2S(a+1)+','+I2S(b-a+1)+','+Hex(src[a],b-a+1)+')'; a:=b+1 end;
        if e<>'data' then begin
          sql:=sql+'UPDATE fand_page SET data='+e+' WHERE file='+sid+' AND pg='+I2S(pg)+';';
          UniqueString(Shadow[k].Data); move(src^,Shadow[k].Data[1],PgSize) end end
      else if len=PgSize then begin
        sql:=sql+'REPLACE INTO fand_page VALUES('+sid+','+I2S(pg)+','+Hex(src^,len)+');';
        k:=ShFind(Gen,pg,true); SetLength(Shadow[k].Data,PgSize); move(src^,Shadow[k].Data[1],PgSize) end
      else begin
        if k>=0 then begin UniqueString(Shadow[k].Data); move(src^,Shadow[k].Data[off+1],len) end;
        sql:=sql+'INSERT INTO fand_page VALUES('+sid+','+I2S(pg)+',CONCAT(REPEAT(X''00'','+
             I2S(off)+'),'+Hex(src^,len)+',REPEAT(X''00'','+I2S(PgSize-off-len)+
             '))) ON DUPLICATE KEY UPDATE data=INSERT(data,'+I2S(off+1)+','+I2S(len)+','+
             Hex(src^,len)+');' end;
      inc(src,len); inc(p,len); dec(left,len) end;
    if p>Size then Size:=p;
    Defer(sql+'UPDATE fand_file SET size=GREATEST(size,'+I2S(Size)+'),ver=ver+1,mtime=UNIX_TIMESTAMP() WHERE id='+sid);
    if Ver>=0 then inc(Ver);
    Pos:=p;
  end;
end;
function MdbSeek(F:longint;Dist:int64;Method:integer):int64;
var rows:TRows;
begin
  with VF[F] do begin
    case Method of
      0:Pos:=Dist;
      1:inc(Pos,Dist);
      2:begin Query('SELECT size FROM fand_file WHERE id='+I2S(Id),rows);
          Size:=StrToInt64(rows[0][0]); Pos:=Size+Dist end end;
    MdbSeek:=Pos;
  end;
end;
function MdbTrunc(F:longint;N:int64):boolean;
var sid:ansistring; off:int64;
begin
  with VF[F] do begin
    sid:=I2S(Id); off:=N mod PgSize;
    Exec('DELETE FROM fand_page WHERE file='+sid+' AND pg>='+I2S((N+PgSize-1) div PgSize)+';'+
         'UPDATE fand_page SET data=CONCAT(LEFT(data,'+I2S(off)+'),REPEAT(X''00'','+I2S(PgSize-off)+
         ')) WHERE file='+sid+' AND pg='+I2S(N div PgSize)+' AND '+I2S(off)+'>0;'+
         'UPDATE fand_file SET size='+I2S(N)+',ver=ver+1,mtime=UNIX_TIMESTAMP() WHERE id='+sid);
    Size:=N; if Pos>N then Pos:=N; if Ver>=0 then inc(Ver); Gen:=NewGen;
  end;
  MdbTrunc:=true;
end;
procedure MdbClose(F:longint);
begin if (F>=0) and (F<=high(VF)) then VF[F].Used:=false end;
function MdbDate(F:longint):longint;
var rows:TRows;
begin
  Query('SELECT mtime FROM fand_file WHERE id='+I2S(VF[F].Id),rows);
  MdbDate:=StrToInt64(rows[0][0]);
end;
function MdbExists(const Path:ansistring):integer;
{ -1 not kept in MariaDB, 0 absent, 1 present }
var k:ansistring; rows:TRows;
begin
  k:=Key(Path); MdbExists:=-1; if k='' then exit;
  Query('SELECT deleted FROM fand_file WHERE path='+HexS(k),rows);
  if length(rows)=1 then MdbExists:=ord(rows[0][0]='0')
  else MdbExists:=ord(FileExists(Path));
end;
function MdbDelete(const Path:ansistring):boolean;
var k:ansistring;
begin
  k:=Key(Path); MdbDelete:=k<>''; if k='' then exit;
  Exec('INSERT INTO fand_file(path,deleted) VALUES('+HexS(k)+',1) ON DUPLICATE KEY UPDATE '+
       'deleted=1,size=0,ver=ver+1,id=LAST_INSERT_ID(id)');
  Exec('DELETE FROM fand_page WHERE file='+I2S(LastId));
end;
function MdbRename(const OldPath,NewPath:ansistring):boolean;
var ko,kn:ansistring; rows:TRows; e:word; f:longint; d:ansistring; h:THandle;
begin
  ko:=Key(OldPath); kn:=Key(NewPath); MdbRename:=(ko<>'') or (kn<>''); if not MdbRename then exit;
  if ko='' then begin
    Import(kn,OldPath,true); SysUtils.DeleteFile(OldPath); exit end;
  if kn='' then begin
    f:=MdbOpen(OldPath,1,e); if f<0 then exit;
    SetLength(d,VF[f].Size); if d<>'' then MdbRead(f,d[1],length(d)); MdbClose(f);
    h:=FileCreate(NewPath); if h<>THandle(-1) then begin
      if d<>'' then FileWrite(h,d[1],length(d)); FileClose(h) end;
    MdbDelete(OldPath); exit end;
  Query('SELECT id FROM fand_file WHERE path='+HexS(ko)+' AND deleted=0',rows);
  if (length(rows)=0) and FileExists(OldPath) then Import(ko,OldPath,false);
  Exec('DELETE p FROM fand_page p JOIN fand_file f ON p.file=f.id WHERE f.path='+HexS(kn)+';'+
       'DELETE FROM fand_file WHERE path='+HexS(kn)+';'+
       'UPDATE fand_file SET path='+HexS(kn)+' WHERE path='+HexS(ko)+';'+
       'INSERT INTO fand_file(path,deleted) VALUES('+HexS(ko)+',1)');
end;

var st:ansistring;function MdbLock(F:longint;Pos,Len:longint):boolean;
var rows:TRows;
begin
  if GetEnvironmentVariable('FAND_MDB_NOLOCK')<>'' then exit(true);
  Query('CALL fand_trylock('+I2S(VF[F].Id)+','+I2S(Pos)+','+I2S(Len)+')',rows);
  MdbLock:=(length(rows)=1) and (rows[0][0]='1');
  if not MdbLock then inc(NConflict);
end;
procedure MdbFlush;
begin if Enabled and (Pending<>'') then Exec('DO 0') end;
procedure MdbUntrust(F:longint);
begin if (F>=0) and (F<=high(VF)) then VF[F].Trusted:=false end;
procedure MdbUnlock(F:longint;Pos,Len:longint);
{ held back with the writes until the next statement or MdbFlush }
begin
  Defer('DELETE FROM fand_lock WHERE file='+I2S(VF[F].Id)+' AND pos='+I2S(Pos)+' AND len='+I2S(Len)+
       ' AND conn=CONNECTION_ID() LIMIT 1');
end;

function MdbRelock(F:longint;OldPos,OldLen,NewPos,NewLen:longint;
  const Check:array of longint;var Stale:longword):boolean;
{ swaps the lock ranges; for the files in Check (-1 none) sets bit i of Stale when
  another connection changed file Check[i] since its cache was read }
var rows:TRows; ids,v,t:ansistring; i,k:longint; now_:int64;
begin
  MdbRelock:=true; Stale:=0;
  if NewLen=0 then begin if OldLen>0 then MdbUnlock(F,OldPos,OldLen); exit end;
  { a step down within the range held cannot conflict: held back, the new range
    taken before the old one goes }
  if (OldLen>0) and (NewPos>=OldPos) and (NewPos+NewLen<=OldPos+OldLen) then begin
    Defer('INSERT INTO fand_lock VALUES('+I2S(VF[F].Id)+','+I2S(NewPos)+','+I2S(NewLen)+',CONNECTION_ID())');
    MdbUnlock(F,OldPos,OldLen); exit end;
  ids:='';
  for i:=0 to high(Check) do if Check[i]>=0 then begin
    if ids<>'' then ids:=ids+','; ids:=ids+I2S(VF[Check[i]].Id) end;
  if GetEnvironmentVariable('FAND_MDB_NOLOCK')<>'' then
    Query('SELECT 1,(SELECT GROUP_CONCAT(id,'':'',ver,'':'',size) FROM fand_file WHERE FIND_IN_SET(id,'''+ids+'''))',rows)
  else
    Query('CALL fand_mode('+I2S(VF[F].Id)+','+I2S(OldPos)+','+I2S(OldLen)+','+I2S(NewPos)+','+
          I2S(NewLen)+','''+ids+''')',rows);
  MdbRelock:=(length(rows)=1) and (rows[0][0]='1');
  if not MdbRelock then begin inc(NConflict); exit end;
  v:=','+rows[0][1]+',';
  for i:=0 to high(Check) do if Check[i]>=0 then with VF[Check[i]] do begin
    { id:ver:size }
    k:=system.pos(','+I2S(Id)+':',v); now_:=-2; t:='';
    if k>0 then begin
      t:=copy(v,k+length(I2S(Id))+2,maxint); t:=copy(t,1,system.pos(',',t)-1);
      now_:=StrToInt64Def(copy(t,1,system.pos(':',t)-1),-2);
      Size:=StrToInt64Def(copy(t,system.pos(':',t)+1,maxint),Size) end;
    if now_<>Ver then begin Stale:=Stale or (longword(1) shl i); Ver:=now_; Gen:=NewGen end;
    Trusted:=k>0 end;
end;

finalization
  if Pending<>'' then Exec('DO 0');
  if Enabled and (GetEnvironmentVariable('FAND_MDB_STATS')<>'') then begin
    st:=Format('mdb: %d queries, %d kB sent, %d kB received, %.3f s waiting, %d lock conflicts'+LineEnding,
               [NQuery,NSent div 1024,NRecv div 1024,QTime,NConflict]);
    FileWrite(StdErrorHandle,st[1],length(st)) end;
  if Sock>=0 then so_close(Sock);
end.
