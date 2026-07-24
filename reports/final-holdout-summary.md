# Holdout final de 2026

## Decisão

`nb_pace_draft` passou todos os critérios pré-registrados e foi promovido
para a V1.

## Amostra

Foram avaliados 1.512 mapas de 2026 que passaram pelos limites
operacionais de equipe, jogador e campeão. Nenhum mapa de 2026 tinha
sido usado para escolher features, modelos ou limites.

## Resultado geral

| Modelo | CRPS | Log Score | Cobertura 90% | Erro médio |
|---|---:|---:|---:|---:|
| Ritmo + draft | 4,4296 | 3,4693 | 90,67% | +0,45 |
| Ritmo | 4,4565 | 3,4744 | 91,01% | +0,85 |
| Baseline por liga | 4,5703 | 3,4994 | 90,01% | +0,14 |

O candidato primário melhorou o CRPS em 0,0269 contra ritmo. O fallback
de ritmo também melhorou 0,1138 contra o baseline por liga.

Em termos relativos, o modelo promovido melhorou o CRPS em 0,60% contra
ritmo e 3,08% contra o baseline por liga. O ganho existe, mas é pequeno.

## Calibração dos intervalos

| Intervalo nominal | Cobertura observada |
|---|---:|
| 50% | 54,43% |
| 80% | 82,08% |
| 90% | 90,67% |

Os intervalos ficaram próximos do objetivo, com leve excesso de
cobertura. Isso significa que estão um pouco mais largos que o ideal,
principalmente no intervalo de 50%.

## Calibração de linhas Over

Brier Score e Log Loss dependem da linha. Não existe um único número
correto para todas as linhas.

| Linha | Over previsto | Over observado | Brier | Log Loss | Intercepto | Slope | ECE |
|---|---:|---:|---:|---:|---:|---:|---:|
| 24,5 | 70,24% | 68,32% | 0,2084 | 0,6040 | -0,069 | 0,970 | 5,58 p.p. |
| 27,5 | 55,76% | 53,31% | 0,2380 | 0,6686 | -0,096 | 0,966 | 5,43 p.p. |
| 30,5 | 41,33% | 38,43% | 0,2274 | 0,6468 | -0,152 | 0,921 | 5,51 p.p. |

Nas três linhas centrais, o modelo superestimou o Over em 1,92 a 2,90
pontos percentuais. O slope ideal é 1 e o intercepto ideal é 0. Os
resultados mostram calibração razoável, mas não perfeita, com viés leve
para o Over e probabilidades um pouco extremas na linha 30,5.

## PIT discreto

O randomized PIT complementar, com seed 20260724, teve média 0,4811
contra 0,5 ideal e variância 0,0824 contra 0,0833 ideal. O maior desvio
entre os dez bins foi 1,60 ponto percentual. O teste KS obteve
`D = 0,0399` e `p = 0,0163`.

A forma geral ficou próxima da uniforme, mas o teste detectou um desvio
pequeno e estatisticamente visível. A média abaixo de 0,5 é compatível
com o erro médio de +0,45 kill: o modelo tende a projetar um total
ligeiramente maior que o realizado.

PIT, slope e ECE foram calculados como diagnóstico complementar depois
da promoção. Eles não fizeram parte do gate congelado original e não
devem ser apresentados como se tivessem participado da decisão.

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

O modelo sustenta uma V1 de pesquisa e acompanhamento prospectivo. Ele
não demonstra, por si só, lucro em apostas, pois não havia histórico
confiável de odds para estimar ROI ou vantagem contra o mercado.
