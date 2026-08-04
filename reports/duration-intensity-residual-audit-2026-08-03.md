# Auditoria da dependência entre duração e intensidade

Data da execução: 2026-08-03.

O diagnóstico foi executado pelo script
`scripts/100_audit_duration_intensity_residuals.R` sobre o candidato ativo
`joint_ml_quadratic_global`. Foram usados somente resultados fora da amostra
registrados em `artifacts/premap_joint_model/map_metrics.rds`.

O resíduo de duração é a diferença entre o log da duração observada e o log
da duração média prevista. O resíduo de intensidade compara a taxa observada
de kills por minuto com a taxa implícita pela média de kills e duração
previstas. A incerteza foi estimada com 2.000 reamostragens em blocos de mês e
série.

## Resultado

Foram analisados 738 mapas. A correlação de Pearson foi -0,1721, com intervalo
bootstrap de 95% entre -0,2392 e -0,0998. A correlação de Spearman foi -0,1750,
com intervalo entre -0,2437 e -0,1032.

O sinal foi negativo nas duas janelas disponíveis: -0,1551 no desenvolvimento
de 2025 Q3 e -0,1793 no diagnóstico secundário de 2026. O resultado também foi
negativo em todas as ligas com pelo menos 30 mapas, mas a magnitude variou.

## Decisão

A independência condicional entre duração e intensidade fica rejeitada como
descrição completa do processo. Isso sustenta criar um challenger correlacionado
ou um termo de intensidade condicionado à duração.

O resultado ainda não promove nenhuma mudança na PMF de produção. A camada de
moneyline atual foi selecionada em uma única janela de desenvolvimento, e 2026
já foi reutilizado como diagnóstico. O novo challenger deve ser ajustado e
comparado nos nove folds rolling-origin, com tuning dentro de cada treino e sem
usar 2026 para seleção.

Status: GO WITH CONDITIONS para o experimento; HOLD para promoção.
