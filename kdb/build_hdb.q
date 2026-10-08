/ Write the date-partitioned HDB (historical database). Run once: make kdb-hdb
/ Layout: /data/hdb/sym (shared symbol list) + /data/hdb/<date>/<table>/<one file per column>
\l /opt/app/gen_data.q

if[not ()~key `:/data/hdb; -2 "HDB already exists; delete kdb/data to rebuild"; exit 1];
db:`:/data/hdb;
src:`daily_prices`trades`quotes!(daily_prices;trades;quotes);
dates:asc distinct daily_prices`date;

/ .Q.dpft[db;date;`sym;`tbl] saves global `tbl (without the date column) into db/date/tbl,
/ enumerates symbol columns against db/sym, sorts by sym and applies the parted (p#) attribute
wr:{[t;d] t set delete date from select from src[t] where date=d; .Q.dpft[db;d;`sym;t]};
{[t] wr[t] each dates; -1 "  ",string[t],": ",string count src t} each key src;
-1 "HDB written: ",string[count dates]," dates";
exit 0
