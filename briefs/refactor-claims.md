# Brief B: una sola autoridad por concepto (los claims) y limpiar los .bak

POR QUE: hoy hay DOS scripts que arbitran si un issue esta libre y NO COINCIDEN: claim-verify.sh y
claim-race.sh (el ultimo esta en ~/.local/share/solidcraft-loop/bin/). Eso ya rompio trabajo dos
veces. Ademas hay 14 archivos .bak de parches mios que confunden a quien lea el directorio.

## LO QUE TENES QUE HACER

1) Determinar cual de los dos es el ARBITRO de verdad, con evidencia:
   - el que decide si un issue esta libre para tomar el trabajo
   - fijate cual usa el resto del sistema de verdad: grep en bin/ y en ~/.local/share/solidcraft-loop/
     por "claim-verify" y por "claim-race": los crons, los scripts de gate, los briefs
   - el que tiene la suite de tests mas completa
2) Dejar el otro como un SHIM: un wrapper chico que llama al arbitrator y devuelve el mismo exit
   code y la misma salida. NO lo borres: otros scripts lo llaman. Que imprima que delega.
3) Que los dos digan SIEMPRE lo mismo. Probalo con casos REALES y pegá las salidas de los dos:
   - un issue LIBRE -> exit 0 en los dos
   - un issue OCUPADO (con un PR abierto que lo reclame) -> exit 1 en los dos
   - un issue con claim VENCIDO -> los dos tienen que decir que esta libre
4) Los .bak: hacé ls bin/*.bak* y un diff de cada .bak contra su version actual. ANTES de borrar
   nada: si un .bak tiene un cambio que la version actual NO tiene, PORTALO a la version actual
   primero (hay .bak con fixes que despues se perdieron). Solo despues borra los .bak.
5) Test nuevo bin/test-claims-authority.sh: verifica que los dos scripts coinciden en los tres casos
   (libre, ocupado, vencido) y devuelven el mismo exit code.

## REGLAS
- Reemplazo atomico (os.replace / mv). NUNCA edites in-place un script que se este ejecutando.
- NO toques: pipeline.py, gate-queue.sh, gate-runner.sh, gate.sh, slot-lock.sh, verify-pr.sh. NO
  toques los tests existentes: escribí el tuyo nuevo aparte.
- NO compiles Rust.
- Al final corré las suites existentes y todas tienen que dar rc=0:
  bash bin/test-gate-quick.sh ; bash bin/test-gate-claim.sh ; bash bin/test-verify-pr.sh ;
  bash bin/test-gate-baseline.sh ; bash bin/test-slot-parallelism.sh ; python3 bin/test-rules.py
  (las que existan; algunas estan en scripts/ en vez de bin/)
- Si una suite falla por una razon que NO es tuya (por ejemplo, porque el owner mergeo upstream y
  cambio la base), decilo con el error exacto y segui: no la arregles a mano.

## LO QUE DEVUELVES
Cual de los dos es el arbitro y con que evidencia; el diff de cada .bak contra su version actual, y
que .bak tenian algo que se perdio (y si lo portaste); la lista de .bak borrados; los tres casos con
la salida de los dos scripts; el rc de las suites y el rc de tu test. No inventes resultados.
