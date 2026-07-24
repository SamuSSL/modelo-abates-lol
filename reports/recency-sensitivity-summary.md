# Sensibilidade de recência e patches

Data da execução: 2026-07-23.

## Desenho

O estudo ampliado usou todo o histórico disponível antes do holdout:

- 2022 como histórico inicial;
- nove folds trimestrais de validação entre 2023 e 2025;
- 7.586 mapas previstos em cada alternativa;
- sete ligas presentes em todos os folds;
- 2026 mantido fechado.

Foram comparadas meias-vidas de 14, 30, 45, 60, 75, 90, 120, 180 e 365 dias.

## Resultado global

| Meia-vida | CRPS | Log Score | Erro médio | Cobertura 90% |
|---:|---:|---:|---:|---:|
| 75 dias | 4,6777 | 3,5869 | -0,651 | 91,42% |
| 90 dias | 4,6777 | 3,5836 | -0,708 | 91,37% |
| 60 dias | 4,6803 | 3,5930 | -0,585 | 91,29% |
| 120 dias | 4,6820 | 3,5809 | -0,801 | 91,22% |
| 45 dias | 4,6871 | 3,6047 | -0,506 | 91,35% |
| 180 dias | 4,6957 | 3,5811 | -0,933 | 90,98% |
| 30 dias | 4,7002 | 3,6300 | -0,400 | 91,22% |
| 365 dias | 4,7282 | 3,5868 | -1,117 | 90,31% |
| 14 dias | 4,7349 | 3,7194 | -0,149 | 91,14% |

O resultado de 75 dias foi praticamente idêntico ao de 90 dias. A diferença pareada foi -0,00005 de CRPS, com intervalo bootstrap de 95% entre -0,00276 e 0,00253.

Sessenta dias também foi estatisticamente indistinguível de 90 dias: diferença de 0,00256, com intervalo entre -0,00327 e 0,00816.

Quatorze e trinta dias foram significativamente piores que 90 dias. Quarenta e cinco dias ficou no limite, com maior probabilidade de degradação.

## Variação por ano

| Ano de validação | Melhor meia-vida | CRPS |
|---:|---:|---:|
| 2023 | 180 dias | 4,6003 |
| 2024 | 90 dias | 4,6824 |
| 2025 | 30 dias | 4,7015 |

O vencedor muda ao longo do tempo. Isso indica aumento da importância de recência em 2025, mas também mostra que uma meia-vida extremamente curta não é estável no histórico completo.

## Tamanho efetivo de amostra por liga

| Meia-vida | Mínimo | Mediana |
|---:|---:|---:|
| 30 dias | 2,5 | 33,4 |
| 60 dias | 19,9 | 70,2 |
| 75 dias | 29,5 | 86,2 |
| 90 dias | 38,9 | 100,0 |
| 180 dias | 102,8 | 182,8 |

Meias-vidas muito curtas deixam algumas ligas praticamente sem histórico recente no início de determinados splits. Nesses casos, o baseline depende excessivamente do prior global.

## Diagnóstico de patches

Foram avaliadas 253 transições consecutivas de patch dentro da mesma liga e temporada, exigindo pelo menos dez mapas em cada patch.

- Mudança absoluta mediana na média de kills: 1,60.
- Mudança absoluta média: 1,96.
- Percentil 90: 4,11.

Há mudanças relevantes entre patches, mas esse diagnóstico também contém variação de equipes, calendário e amostra. Ele não autoriza usar patch como feature.

## Proposta

Adotar meia-vida de 60 dias como configuração operacional inicial e manter 90 dias como challenger.

Sessenta dias responde mais rapidamente às mudanças do jogo, reduz o viés médio e não apresentou perda estatisticamente conclusiva de CRPS contra 90 dias. Ao mesmo tempo, preserva amostra efetiva muito maior do que 14 ou 30 dias.

Essa proposta ainda precisa de aprovação. O modelo deverá manter shrinkage e registrar separadamente contagem bruta e amostra efetiva.

## Artefatos

- `reports/recency-sensitivity.html`
- `artifacts/evaluation/recency_sensitivity_map_metrics.rds`
- `artifacts/evaluation/recency_sensitivity_summary.csv`
- `artifacts/evaluation/recency_sensitivity_by_year.csv`
- `artifacts/evaluation/recency_sensitivity_by_fold.csv`
- `artifacts/evaluation/recency_sensitivity_by_league.csv`
- `artifacts/evaluation/recency_effective_sample.csv`
- `artifacts/evaluation/recency_performance_by_patch.csv`
- `artifacts/evaluation/patch_transitions.csv`
