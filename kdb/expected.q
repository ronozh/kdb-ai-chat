/ Expected answers for the section 6 tests, computed directly in q. Run: make kdb-expected
\l /hdb
t:select from daily_prices; L:max t`date;   / pull the partitioned table into memory (26k rows)
-1 "1  close T001 2026.06.15: ",string exec first close from t where sym=`T001,date=2026.06.15;
-1 "2  MA20 T010 as of ",string[L],": ",string avg -20#exec close from t where sym=`T010;
m:update pct:100*-1+close%prev close by sym from t;
-1 "3  biggest |move| since 2026.07.01: ",.Q.s1 first `a xdesc select sym,date,pct,a:abs pct from m where date>=2026.07.01;
-1 "4  avg volume T050 Q1 2026: ",string exec avg volume from t where sym=`T050,date within 2026.01.01 2026.03.31;
-1 "5  top 5 1y return: ",.Q.s1 5#`ret xdesc select ret:-1+last[close]%first close by sym from t;
-1 "6  T001 on Saturday 2026.06.13: rows=",string count select from t where sym=`T001,date=2026.06.13;
-1 "7  T999: rows=",string count select from t where sym=`T999;
-1 "8  rows for T001 (must stay 261 after delete request): ",string count select from t where sym=`T001;
exit 0
