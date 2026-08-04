# Auditoria autenticada de team totals e duração

Data da execução: 30 de julho de 2026.

## Decisão

Os mercados de kills por equipe estão disponíveis como mercados padrão. Eles
devem permanecer em pesquisa como fonte de informação sobre a distribuição dos
abates entre as equipes, mas não devem ser promovidos ao modelo operacional
neste momento.

Não foi encontrado um mercado de duração acessível pela conta atual. Nenhuma
fixture armazenada possui unidade relacionada a tempo ou duração, e o endpoint
de specials retornou HTTP 403. Portanto, ainda não é possível auditar ou derivar
diretamente a expectativa de duração da Pinnacle por esta assinatura.

O modelo operacional continua sendo `liga + pace`.

## Contrato autenticado

A auditoria consultou um evento liquidado de cada uma das 13 competições
manifestadas. Em todas elas:

- `home_totals` retornou linhas para kills da equipe da casa;
- `away_totals` retornou linhas para kills da equipe visitante;
- `period` representou o número do mapa;
- `odds1/todds1` foi tratado como Over;
- `odds2/todds2` foi tratado como Under;
- a orientação casa/visitante foi preservada até o settlement.

O endpoint de fechamento pode retornar várias linhas por período. Elas
representam linhas que foram principais em momentos diferentes. A linha de
fechamento usada na avaliação é a de timestamp mais recente por
`event_id + period + market`.

## Coleta

| Item | Resultado |
|---|---:|
| Eventos de kills | 1.286 |
| Requisições esperadas de abertura e fechamento | 5.144 |
| Requisições concluídas de abertura e fechamento | 5.144 |
| Linhas normalizadas de abertura | 11.659 |
| Linhas normalizadas de fechamento | 11.659 |
| Requisições esperadas de histórico completo | 2.572 |
| Requisições históricas concluídas | 858 |
| Snapshots históricos normalizados | 180.784 |
| Observações T-15 a T-30 vinculadas e avaliáveis | 1.782 |

Abertura e fechamento possuem cobertura integral para o manifesto atual. O
histórico completo está em 33,4%. A coleta parou após o guardrail de quota. O
processamento é retomável e não repetirá requisições já concluídas.

## Eficiência das linhas

| Snapshot | Observações | Over realizado | Probabilidade Over sem vig | Brier | Log Loss | AUC | MAE da linha | Viés kills menos linha |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Fechamento | 5.418 | 48,47% | 49,99% | 0,2498 | 0,6928 | 0,5151 | 5,58 | -0,11 |
| T-15 a T-30 | 1.782 | 48,71% | 49,93% | 0,2503 | 0,6937 | 0,4994 | 5,75 | -0,26 |

As linhas ficaram próximas de 50% no agregado e apresentaram pouco viés. Isso é
compatível com um mercado bem centrado, mas não prova eficiência econômica.

AUC é pouco informativa neste teste. Cada observação usa uma linha diferente e
a Pinnacle desloca a linha até os dois lados ficarem próximos de 50%. Assim, há
pouca variação de probabilidade para ordenar. Calibração da linha, CLV e retorno
contra preços de softs são critérios mais úteis.

As células por liga ainda variam. Algumas têm menos de 100 observações no lote
T-15. Elas não sustentam decisões de aposta isoladas.

## Comparação com liga + pace

Foram encontrados 414 mapas com previsão out-of-fold do fundamental e dois
team totals disponíveis entre 15 e 30 minutos antes do fechamento.

| Candidato | Peso do mercado | MAE | RMSE | Correlação com o total |
|---|---:|---:|---:|---:|
| Liga + pace | 0% | 6,240 | 7,930 | 0,206 |
| Blend fixo | 25% | 6,241 | 7,921 | 0,214 |
| Blend fixo | 50% | 6,259 | 7,928 | 0,211 |
| Blend fixo | 75% | 6,289 | 7,951 | 0,203 |
| Soma das linhas por equipe | 100% | 6,321 | 7,991 | 0,193 |

A soma das linhas por equipe não melhorou o erro médio do `liga + pace`. O
blend de 25% reduziu o RMSE em apenas 0,009 e piorou ligeiramente o MAE. Esse
resultado é pequeno, exploratório e insuficiente para promoção.

A correlação observada entre kills das duas equipes foi -0,393 no overlap. Isso
reforça a necessidade de preservar dependência na divisão dos abates, mas não
define sozinho a distribuição correta.

## Próximos gates

1. Retomar as 1.714 requisições históricas pendentes após a renovação da quota.
2. Repetir a avaliação T-15 com cobertura completa e bootstrap por série e
   tempo.
3. Testar team totals como alvo de calibração da alocação Beta-Binomial, sem
   assumir que a soma das linhas seja exatamente a média esperada.
4. Manter o modelo interno de duração até existir uma fonte de mercado
   auditável ou uma fórmula externa formalmente especificada.
5. Só construir o Monte Carlo informado pela Pinnacle se a informação por
   equipe melhorar CRPS ou Log Score fora da amostra e não piorar ligas.
6. Validar vantagem contra softs com odds e timestamps reais. A linha Pinnacle
   servirá como benchmark e fonte de CLV, não como prova isolada de edge.

## Artefatos

- `artifacts/bettingiscool_team_totals/authenticated_audit_summary.csv`
- `artifacts/bettingiscool_team_totals/team_totals_coverage_summary.csv`
- `artifacts/bettingiscool_team_totals/team_totals_coverage_by_league.csv`
- `artifacts/bettingiscool_team_totals/team_totals_efficiency_metrics.csv`
- `artifacts/bettingiscool_team_totals/team_totals_vs_fundamental.csv`
- `artifacts/bettingiscool_team_totals/team_totals_allocation_diagnostics.csv`

As respostas brutas foram preservadas localmente com parâmetros, timestamp e
SHA-256. A chave não foi gravada em código, configuração, logs ou artefatos.
