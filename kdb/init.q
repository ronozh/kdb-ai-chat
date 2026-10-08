/ KDB-X startup: load the HDB, SQL interface, security.
/ Run as: q init.q   with env KDB_USER (the only user allowed in) and the HDB mounted read-only at /db.
/ The port is opened at the end, only after security is in place.
.sec.user:`$getenv`KDB_USER;
if[null .sec.user; -2 "fatal: KDB_USER not set"; exit 1];
if[()~key `:/db/sym; -2 "fatal: no HDB at /db (run: make kdb-hdb)"; exit 1];
\l /db
.s.init[];
/ Warm the per-partition row-count cache (.Q.PN). Counting writes it, which reval would block for clients.
{count value x} each tables[];

/ ---- security ----
/ Credentials file (outside the working dir /db, so reval can't read it): user:salt:sha1hex(salt,password).
/ Re-read on every login, so `make kdb-user` takes effect without a restart and no hashes sit in memory.
.sec.creds:{{(`$x[;0])!1_'x}":"vs'read0 hsym`$getenv`KDB_USERS_FILE};
@[.sec.creds;::;{-2 "fatal: cannot read credentials file: ",x; exit 1}];   / fail closed
/ Only KDB_USER may log in.
.z.pw:{[u;p] c:@[.sec.creds;::;{()!()}];
  $[null u;0b;u<>.sec.user;0b;not u in key c;0b;c[u;1]~raze string -33!c[u;0],p]};

/ Read-only. reval blocks writes to globals, system calls and file access outside the working dir (/db).
/ The HDB view is also mounted read-only, so the files can't change even outside reval.
/ KX SQL (.s.e) writes an internal counter, so it fails under reval and under -b (-b is therefore not used).
/ Exception: the MCP server's exact SQL call runs .s.e directly, only for a single SELECT/WITH statement
/ whose KX parse tree contains no q-escape function. .s.e runs OUTSIDE reval (it needs to write an internal
/ counter), so without this a crafted SELECT could use KX SQL's q(...) / qt(...) escapes to run arbitrary q.
.sec.sqlCall:"{r:.s.e x;`rowCount`data!(count r;.j.j y sublist r)}";
.sec.isSqlCall:{$[0h<>type x;0b;3<>count x;0b;.sec.sqlCall~x 0]};
/ drop '...' literals and "..." identifiers in one left-to-right pass (state = open quote char, or " ")
.sec.unquote:{[s] st:{$[x=" ";$[y in "'\"";y;" "];x=y;" ";x]}\[" ";s]; s where (st=" ")&not s in "'\""};
.sec.readOnly:{[q]
  if[10h<>type q;:0b];
  u:upper .sec.unquote q;
  if[(";" in u) or any((u="-")&next[u]="-")or(u="/")&next[u]="*";:0b];   / single statement, no comments
  w:(" "vs @[u;where not u within "AZ";:;" "]) except enlist"";
  $[not first[w] in ("SELECT";"WITH");0b;
    any w in ("INSERT";"UPDATE";"DELETE";"CREATE";"DROP";"ALTER";"TRUNCATE";"INTO";"MERGE";"REPLACE";"UPSERT";"GRANT");0b;
    1b]};
.sec.trim:{[q] $[10h<>type q;q;{(neg sum mins reverse x in " \t\r\n;")_x}trim q]};   / drop trailing ;
/ Function names called in the SQL: an identifier run before '(' (any whitespace before '(' skipped).
/ Works on unquoted text, so string literals can't hide a call. Distinguishes the q(...)/qt(...) escapes
/ from a table alias `q` or a qualified column q."date" (neither is followed by '('). '.' is an identifier
/ char here so a dotted q call like .s.F(...) is captured whole and blocked by the "*.*" check below.
.sec.idc:{x in ".",.Q.A,"0123456789_"};
.sec.fnames:{[sql]
  u:upper .sec.unquote sql;
  back:{[u;p] while[(p>0)&u[p-1] in " \t\r\n";p-:1]; n:0; while[(p>n)&.sec.idc u (p-1)-n; n+:1]; `$u[(p-n)+til n]};
  distinct back[u] each where u="("};
.sec.qEscape:`Q`QT;   / KX SQL functions that evaluate q; must never reach .s.e (they run outside reval)
.sec.sql:{[q;n] if[not (type n) in -5 -6 -7h;'"bad row limit"];   / n reaches sublist unrestricted
  q:.sec.trim q; if[not .sec.readOnly q;'"read-only: only a single SELECT/WITH statement is allowed"];
  f:.sec.fnames q;   / block q(...)/qt(...) and any dotted q call such as .s.F(...)
  if[(any .sec.qEscape in f) or any f like "*.*";'"q-escape functions (q/qt/.s.*) are not allowed"];
  r:.s.e q; `rowCount`data!(count r;.j.j n sublist r)};
/ audit log: one line per remote query
/ wide console so the audit log shows whole queries (q truncates printed values to the console width)
\c 50 5000
.sec.log:{[k;x] -1 " "sv(string .z.p;string .z.u;k;-3!x);};
/ like the default handler: a ("fn-as-string";args..) call resolves the string first, all inside reval
.sec.app:{$[(0h=type x)&10h=type first x;(value first x). 1_x;value x]};
.z.pg:{.sec.log["sync";x]; $[.sec.isSqlCall x;.sec.sql . 1_x;reval(.sec.app;enlist x)]};
.z.ps:{.sec.log["async";x]; reval(.sec.app;enlist x)};

/ no HTTP or websocket query paths
.z.ph:{.h.hn["403 Forbidden";`txt;"forbidden"]};
.z.pp:.z.ph;
.z.ws:{neg[.z.w] "forbidden"};

-1 "user ",string[.sec.user],"; tables ",(", "sv string tables[]),"; ",string[count date]," dates ",string[first date]," to ",string last date;

/ open the port last: if anything above failed, nothing is exposed
\p 5000
