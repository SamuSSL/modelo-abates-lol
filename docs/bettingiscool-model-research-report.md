# BettingIsCool, backtest e evolução do modelo

Data da execução: 2026-07-28.

## Estado e decisão

Classificação atual: **GO WITH CONDITIONS** para completar o backtest histórico
e manter o ensemble em shadow. **HOLD** para qualquer afirmação de edge
econômico ou promoção operacional.

O Streamlit, a API pública e o bundle operacional não foram alterados.

O armazenamento canônico foi reconciliado. O RDS e o DuckDB agora possuem
13.770 mapas; 11.883 satisfazem o contrato atual de alvo e elegibilidade.

## Contrato de mercado verificado

O manifesto usa `sport_id=12`, `resulting_unit=Kills`, `market=totals`,
`period` como mapa, histórico completo e somente linhas principais. O contrato
fixa `odds1/todds1` como Over e `odds2/todds2` como Under, conforme a referência
de campos da documentação da BettingIsCool.

Uma verificação autenticada do evento LCK `1609632978` confirmou períodos 1,
2 e 3, linhas, odds brutas, true odds e settlements por mapa.

A auditoria encontrou uma divergência relevante em relação ao plano inicial:
o `cutoff` retornado no histórico é o mesmo para todos os mapas da série. O
timestamp final da linha principal é diferente por `period`. Por isso, o
snapshot primário é a última linha aberta até cinco minutos antes do timestamp
final específico do período. Usar o `cutoff` da série para mapas 2 ou 3
introduziria vazamento.

O endpoint de fechamento devolve linhas alternativas mesmo quando recebe
`main_lines_only=1`. A linha principal de fechamento é identificada pela linha
final do histórico já filtrado por `main_lines_only=1`.

## Infraestrutura entregue

O cliente usa a chave somente de `BETTINGISCOOL_API_KEY`, monitora quota,
truncamento e retry, e preserva respostas brutas privadas com parâmetros,
timestamp e SHA-256.

O DuckDB contém as tabelas `market_fixtures`, `market_odds_snapshots`,
`market_opening`, `market_closing`, `market_settlements`,
`game_market_links`, `api_ingestion_state` e a view
`market_backtest_view`.

O coletor é retomável e idempotente. Fixtures são consultados em janelas de
90 dias, abaixo do limite de 1.000 registros, e cada evento de kills recebe
histórico, abertura, fechamento e settlement. Snapshots possuem chave
determinística e são deduplicados também dentro da própria resposta.

A coleta concluída contém 1.286 fixtures de kills, 265.478 snapshots
históricos de linha principal, 32.704 registros de abertura, 32.628 registros
de fechamento e 3.755 settlements por mapa. O backfill terminou com 91.979
tokens diários restantes.

O matching aceita automaticamente apenas liga, data, par não ordenado de
equipes, alias versionado e período exatos. Settlement valida o vínculo depois
da escolha. Os estados possíveis são `verified`, `ambiguous`, `unmatched`,
`cancelled` e `conflict`.

O matching final classificou 2.751 mapas como `verified`, 796 como
`cancelled`, 188 como `unmatched`, 19 como `conflict` e 4 como `ambiguous`.
O backtest recebeu 2.708 dos mapas verificados; os demais não tinham o
snapshot primário `.5` completo e elegível.

## Experimentos do memorando

Todos os resultados abaixo usam os mesmos nove folds rolling-origin e 7.586
previsões OOF de desenvolvimento.

| Experimento | CRPS | Log Score | Conclusão |
|---|---:|---:|---|
| V1 original | 4,562152 | 3,492431 | Referência |
| Ensemble shadow | 4,540116 | 3,488402 | Melhor referência, ainda não promovida |
| IDR sobre V1 | 4,617736 | 4,187066 | Rejeitar |
| IDR sobre shadow | 4,562611 | 4,070299 | Rejeitar |
| Referência Ridge de quatro variáveis | 4,572091 | 3,497949 | Referência comum dos blocos |
| Draft assimétrico | 4,558064 | 3,494194 | Sinal exploratório, dentro de um erro-padrão |
| RW1 global semanal | 4,584419 | 3,501236 | Rejeitar |
| Matchup de arquétipos | 4,633658 | 3,510726 | Rejeitar |
| Modelo dirigido com lado Blue/Red | 4,571153 | 3,503601 | Não supera a V1 |

O efeito de lado foi avaliado no modelo dirigido equipe-mapa, onde Blue/Red é
identificável. Ele não foi colocado como constante no total agregado.

O bloco assimétrico é o único challenger novo com resultado pontual melhor que
a referência Ridge, mas não demonstrou superioridade estável. Não entra em
modelo combinado nem no bundle.

## Auditoria e simplificação

Retirar `pace` piorou o CRPS para 4,630857 e perdeu em todos os nove folds.
Retirar `draft_frontline` piorou para 4,599144. Ambos permanecem.

`league`, `draft_burst` e `draft_frontline_imbalance` ficaram equivalentes no
agregado. As ablações iterativas chegaram a `pace + draft_frontline`, com CRPS
4,574928, e à mesma dupla sem liga, com CRPS 4,575345.

A regra exige também ausência de piora por liga. As versões menores pioraram
pontualmente CBLOL, LEC ou outras ligas. Portanto, nenhuma retirada passa todos
os guardrails. A V1 permanece inalterada. O catálogo completo está em
`artifacts/evaluation/variable_catalog_review.csv`.

## Backtest econômico

O backtest implementado avalia a PMF na linha real `.5`, Brier, Log Loss,
probabilidade sem vig da BettingIsCool, no-vig multiplicativo, stake fixa,
lucro, yield, drawdown e CLV. Nenhuma odd é usada como feature.

Maio a dezembro de 2025 permanece desenvolvimento econômico exploratório.
2026 é comparação secundária, não holdout limpo. O resultado histórico não
autoriza afirmar edge; a decisão econômica continua condicionada ao shadow
prospectivo posterior ao cutoff congelado.

Nos 2.708 mapas comuns, o ensemble shadow obteve Brier 0,249158 e Log Loss
0,691525, contra 0,249683 e 0,692521 do mercado sem vig. As diferenças por
bootstrap atravessam zero. A estratégia mecânica de qualquer EV positivo fez
1.741 apostas, lucro de 32,887 unidades e yield de 1,89%, mas o intervalo de
95% do yield foi de -2,37% a 6,25%.

O CLV médio do ensemble foi -3,75%, com intervalo de -4,41% a -3,14%. Isso é
incompatível com evidência de edge sustentável. O ROI histórico positivo é
tratado como ruído amostral ou seleção retrospectiva, não como sinal para
promoção.
