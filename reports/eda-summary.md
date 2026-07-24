# Resumo da EDA e seleção temporal

Data da execução: 2026-07-23.

## Escopo

A EDA utilizou 10.173 mapas válidos das sete ligas anteriores a 2026-01-01. O holdout de 2026 permaneceu fora dos cálculos de distribuição, associação e seleção.

Um registro interrompido da LCK foi excluído exatamente por `gameid`. Não foi aplicado limiar de duração.

## Distribuição

- Média: 26,864 kills.
- Mediana: 26 kills.
- Desvio-padrão: 8,390 kills.
- Faixa observada: 3 a 66 kills.
- A razão variância/média ficou entre 2,35 e 2,74 nas sete ligas.

A sobredispersão é incompatível com a hipótese Poisson simples como descrição suficiente. Poisson permanece baseline obrigatório, mas Negative Binomial deve ser o primeiro modelo de contagem challenger.

## Drift

| Temporada | Mapas | Média de kills |
|---|---:|---:|
| 2022 | 2.537 | 25,753 |
| 2023 | 2.525 | 25,728 |
| 2024 | 2.427 | 26,750 |
| 2025 | 2.684 | 29,085 |

O aumento em 2025 justifica testar recência forte. O relatório visual apresenta o drift mensal separadamente por liga para evitar confundir mudança de calendário com mudança do target.

## Associações descritivas

| Variável | Medida | Associação | Tratamento |
|---|---|---:|---|
| duração | Spearman | 0,338 | challenger de duração |
| liga | razão de correlação | 0,145 | feature com pooling |
| temporada | razão de correlação | 0,166 | adapter temporal |
| patch | razão de correlação | 0,217 | apenas diagnóstico |
| playoffs | razão de correlação | 0,058 | apenas diagnóstico |

Essas associações não autorizam usar duração observada, patch ou playoffs como features.

## Seleção da janela

Foram comparadas dez alternativas pré-registradas em 2.634 mapas dos três folds de 2025.

| Candidato | CRPS | Log Score | Cobertura 90% |
|---|---:|---:|---:|
| meia-vida de 90 dias | 4,7260 | 3,5865 | 92,03% |
| janela fixa de 12 meses | 4,7721 | 3,6653 | 91,31% |
| meia-vida de 180 dias | 4,7959 | 3,5900 | 91,57% |
| janela fixa de 18 meses | 4,8438 | 3,6352 | 91,31% |

O corte de temporada atual obteve CRPS 4,6721, mas completou apenas dois folds e é inelegível para a comparação principal.

A meia-vida de 90 dias superou a janela de 12 meses nos três folds. A diferença pareada de CRPS foi -0,0461, ou -0,97%, com intervalo bootstrap temporal de 95% entre -0,0621 e -0,0321.

Por liga, a meia-vida de 90 dias melhorou LCK, LCS e LPL. Houve piora pontual em CBLOL, LEC, LES e LFL, entre 0,0081 e 0,0204 de CRPS. Ainda não existe limiar aprovado para classificar essa degradação como material.

## Recomendação

Usar meia-vida exponencial de 90 dias como recomendação de desenvolvimento. A decisão permanece pendente de aprovação antes de congelar a janela.

O baseline ainda subestima o target em média por 1,114 kills e apresenta intervalos conservadores. Isso deverá ser tratado pelos modelos de contagem e pelos guardrails de calibração, sem abrir o holdout.

## Artefatos

- `reports/eda.html`
- `reports/feature-association.html`
- `docs/feature-catalog.md`
- `artifacts/evaluation/window_map_metrics.rds`
- `artifacts/evaluation/window_summary.csv`
- `artifacts/evaluation/window_bootstrap_comparison.csv`
- `artifacts/evaluation/window_stability_by_fold.csv`
- `artifacts/evaluation/window_stability_by_league.csv`
