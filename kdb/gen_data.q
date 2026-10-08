/ Simulated daily prices for 100 fictional tickers. Deterministic (fixed seed).
\S 42

daily_prices:{[]
  dates:d where 1<(d:2025.10.01+til 365) mod 7;   / weekdays only (2000.01.01 was a Saturday)
  syms:`$"T",/:-3#'"00",/:string 1+til 100;
  / fictional names: prefix x suffix combos
  pre:("Acme";"Borealis";"Cobalt";"Dunmore";"Ember";"Fjord";"Granite";"Halcyon";"Ironwood";"Juniper");
  suf:("Analytics";"Biotech";"Capital";"Dynamics";"Energy";"Foods";"Holdings";"Logistics";"Materials";"Systems");
  names:`$raze pre,/:\:" ",/:suf;
  n:count dates;
  randn:{[k] sqrt[-2*log 1-k?1f]*cos 2*acos[-1]*k?1f};   / standard normal (Box-Muller)
  start:10+100?490f;                                      / start price 10-500
  / geometric random walk, ~2% daily vol, rounded to cents
  closes:{[n;rn;s] 0.01*floor 0.5+100*s*exp sums 0f,(n-1)#0.02*rn n}[n;randn]each start;
  vols:100000+(100*n)?5000000;
  `date`sym xasc ([] date:raze 100#enlist dates; sym:raze n#'syms; name:raze n#'names; close:raze closes; volume:vols)
  }[];
