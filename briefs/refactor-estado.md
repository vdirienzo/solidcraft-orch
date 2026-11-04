# Brief C: partir el state.json en archivos por concepto, sin romper nada

POR QUE: state.json tiene 144 KB y es un bloque unico: PRs, merges, slots, hardware, politicas, bugs
del loop, candidatos, todo junto. Nadie puede leerlo entero y encima se contradice con queue.txt y con
los locks. Hay que partirlo por concepto, SIN que nada se rompa.

## LO QUE TENES QUE HACER

1) Inventario: leer el state.json actual y listar sus claves de primer nivel con cuantas entradas
   tiene cada una. Pegalo en el informe: eso define los archivos.
2) Partirlo en un subdirectorio state/ con un archivo por concepto, segun las claves reales que
   encontré. Como minimo estos grupos: prs (PRs abiertos y merges), slots (slots, locks, ocupacion),
   gates (verdicts, baseline, cola), claims (claims y issues abandonadas), policy (politicas y topes),
   notes (lo que no es dato estructurado: bugs del loop, lecciones, hardware).
3) state.json TIENE QUE SEGUIR EXISTIENDO y seguir siendo valido para todos los scripts que lo leen:
   es un requisito, no una preferencia. Resolvelo asi (elegi una y justificala):
   a) state.json se GENERA a partir de los archivos de state/ (un merge-state.sh que los junta): un
      consumidor que lee state.json sigue funcionando igual
   b) state.json se vuelve un archivo chico que dice que ahora vive en state/
   La (a) es la mejor si es simple de hacer.
4) merge-state.sh (o el nombre que le des) que:
   - reconstituya state.json desde state/*.json
   - tenga un --check que verifique que el state.json RECONSTRUIDO es identico (semanticamente: mismas
     claves de primer nivel, mismos valores) al de antes de partirlo. Ese check es lo que prueba que
     no rompiste nada.
   - escriba a un temporal, compare, y solo despues reemplace.
5) Test bin/test-state-split.sh: que corra el merge --check y falle si state.json no se reconstruye
   igual; y que falle si alguien mete una clave nueva de primer nivel en state.json a mano sin
   pasarla por los archivos de state/.

## REGLAS
- Reemplazo atomico (os.replace / mv). NUNCA escribas state.json in-place: lo leen los crons
  (solidcraft-pipeline cada 5 min, solidcraft-gate-queue cada 3 min) y todos los scripts.
- NO toques: pipeline.py, gate-queue.sh, gate-runner.sh, gate.sh, slot-lock.sh, claim-*.sh,
  verify-pr.sh. NO toques los tests existentes: escribí el tuyo nuevo aparte.
- NO compiles Rust.
- ANTES de cambiar nada: copiá state.json a
  /home/user/.local/share/solidcraft-orch/logs/state.json.pre-split.bak
- Al final corré las suites existentes y todas tienen que dar rc=0:
  bash bin/test-gate-quick.sh ; bash bin/test-gate-claim.sh ; bash bin/test-verify-pr.sh ;
  bash bin/test-gate-baseline.sh ; bash bin/test-slot-parallelism.sh ; python3 bin/test-rules.py
  (las que existan; algunas estan en scripts/ en vez de bin/)
- Si una suite falla por una razon que NO es tuya (el owner mergeo upstream y cambio la base),
  decilo con el error exacto y segui: no la arregles a mano.

## LO QUE DEVUELVES
El inventario de claves con sus conteos, la lista de archivos created, como resolviste la
compatibilidad de state.json, la salida del --check (identico: si/no), el rc de las suites y el rc de
tu test. Si algo no lo pudiste hacer, decilo con el error exacto. No inventes resultados.
