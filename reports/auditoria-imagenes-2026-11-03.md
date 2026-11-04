# El costo de mirar imagenes (medido contra el provider, 2026-11-03)

Endpoint: `https://api.minimax.io/anthropic/v1/messages`, modelo `MiniMax-M3.1-Flash`.
La key se leyo de `~/.hermes/.env` en el momento y no quedo en ningun artefacto.

| Contenido | input_tokens | Bytes |
|---|---|---|
| solo texto | 8 | - |
| imagen 1600x1000 (la de evidencia) | 2097 | 242 KB |
| la misma a 800x500 | 531 | 103 KB |
| recorte de 400x300 de la misma | 174 | 49 KB |
| la misma imagen mandada dos veces | 1 (+ cache_read) | 103 KB |

## Lo que dice

- El costo sigue a los PIXELES, no a los bytes: ~1300 tokens por megapixel.
  Encaja con un patching de 28x28: 1600/28 x 1000/28 = 2052 + 8 del texto = 2060, medido 2097.
- Una captura de evidencia completa son ~2100 tokens: menos del 1% de un request de 270k.
  Mirar imagenes NO es el gasto grande.
- Recortar la region que importa baja 12x (2097 -> 174).
- Repetir la misma imagen es gratis: el provider la sirve del prompt cache.

## La regla

- Para verificar un texto o un rotulo: recorte con `region`, no la ventana entera.
- Al delegar, pasar el recorte que el subagente necesita, no la captura completa.
- El tamano de la PNG que se SUBE a un PR es una decision de legibilidad, no de tokens: ahi 1600x1000 esta bien.
