# Holdout final de 2026

## Decisão

`nb_pace_draft` passou todos os critérios pré-registrados e foi promovido
para a V1.

## Amostra

Foram avaliados 1.512 mapas de 2026 que passaram pelos limites
operacionais de equipe, jogador e campeão. Nenhum mapa de 2026 tinha
sido usado para escolher features, modelos ou limites.

## Resultado geral

| Modelo | CRPS | Cobertura 90% | Erro médio |
|---|---:|---:|---:|
| Ritmo + draft | 4,4296 | 90,67% | +0,45 |
| Ritmo | 4,4565 | 91,01% | +0,85 |
| Baseline por liga | 4,5703 | 90,01% | +0,14 |

O candidato primário melhorou o CRPS em 0,0269 contra ritmo. O fallback
de ritmo também melhorou 0,1138 contra o baseline por liga.

## Guardrails

Todos passaram: CRPS, cobertura, erro médio, PMFs finitas, massa de
cauda e degradação máxima por liga.

Draft melhorou em seis das sete ligas. Na LEC, piorou 0,0513 contra
ritmo. Esse valor ficou abaixo do limite pré-registrado de 0,10; por
isso não bloqueou a promoção. O segmento deve ser acompanhado
prospectivamente.

## Conclusão

O resultado fora da amostra confirma a hipótese central da V1: ritmo
recente das equipes é o sinal principal, e uma descrição simples da
composição adiciona informação útil. Estatísticas individuais não
foram necessárias.
