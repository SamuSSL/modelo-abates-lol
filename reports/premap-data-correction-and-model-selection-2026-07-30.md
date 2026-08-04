# Correção dos dados e seleção do modelo pré-mapa

Data da execução: 2026-07-30

## Decisão

O modelo operacional continua sendo a Binomial Negativa com liga e pace.

Attack, concession, KPM, DPM, duração e volatilidade permanecem disponíveis
para pesquisa, mas nenhum desses blocos passou os critérios de promoção. O
modelo conjunto dirigido e o modelo informado pela moneyline permanecem em
sombra.

First Blood e GSPD estão excluídos do conjunto ativo de variáveis. Os campos
brutos foram preservados apenas para auditoria e possível reconsideração
futura.

## Correção de integridade

`teamdeaths` não representa exatamente os abates do adversário porque inclui
execuções e outras mortes sem crédito de kill. A concessão de uma equipe agora
é definida pelos `teamkills` do adversário.

O pipeline preserva:

- `reported_team_deaths`: valor bruto do Oracle's Elixir;
- `opponent_kills`: abates do adversário;
- `neutral_deaths`: diferença entre mortes brutas e abates do adversário;
- `team_deaths`: alias compatível que agora representa concessão;
- `total_kills_game`: soma dos abates das duas equipes.

Foram encontrados 671 registros de equipe, em 662 mapas, com diferença entre
mortes brutas e abates do adversário. A diferença máxima foi de 3. Depois da
correção, houve zero divergências entre o total derivado e o total canônico.

O bruto possui 11.884 mapas-alvo antes das exclusões explícitas. O mapa
`ESPORTSTMNT01_3408461` é uma captura abortada já documentada. Depois da
exclusão, permanecem 11.883 mapas-alvo canônicos.

## Validação temporal fundamental

Resultados rolling-origin de 2023 a 2025, com 7.586 previsões por candidato:

| Modelo | CRPS | Log Score | Cobertura 90% | Diferença de CRPS contra liga + pace |
|---|---:|---:|---:|---:|
| Liga + pace | 4,5861 | 3,4981 | 91,60% | referência |
| Dirigido, temporada + últimos 15 | 4,6188 | 3,5258 | 95,69% | +0,0327 |
| Dirigido, todas as janelas | 4,6247 | 3,5268 | 95,68% | +0,0386 |
| Dirigido, últimos 15 | 4,6483 | 3,5319 | 95,81% | +0,0622 |

Para o melhor modelo dirigido, o intervalo bootstrap de 95% da diferença de
CRPS contra liga + pace foi de +0,0087 a +0,0544. Todo o intervalo favorece o
baseline. O modelo dirigido também produziu intervalos excessivamente largos.

## Ablações das variáveis de equipe

| Modelo | CRPS | Log Score | Cobertura 90% |
|---|---:|---:|---:|
| Liga + pace | 4,5861 | 3,4981 | 91,60% |
| Ridge com pace + intensidade dos últimos 15 | 4,5903 | 3,5019 | 93,44% |
| Ridge com pace + expectativa direta dos últimos 15 | 4,5916 | 3,5022 | 93,44% |
| Ridge somente com pace | 4,6014 | 3,5045 | 93,30% |
| Ridge com todos os ratios | 4,6015 | 3,5039 | 93,16% |

A regra do menor modelo equivalente selecionou liga + pace. Nenhuma janela ou
combinação dos ratios melhorou simultaneamente CRPS e Log Score.

## Fórmulas multiplicativas e duração

As fórmulas puras também ficaram atrás:

| Modelo | CRPS | Log Score |
|---|---:|---:|
| Liga + pace | 4,5861 | 3,4981 |
| KPM/DPM com expoentes regularizados | 4,6161 | 3,5071 |
| KPM/DPM com pesos otimizados | 4,6196 | 3,5102 |
| Attack/concession com expoentes regularizados | 4,6238 | 3,5092 |

Para duração isolada, a lognormal regularizada foi a melhor especificação:
CRPS 3,0527, MAE 4,3234 minutos e cobertura de 89,40% no intervalo nominal de
90%. A duração melhora a interpretação do mecanismo, mas sua inclusão no
modelo conjunto não melhorou a distribuição do total de kills.

## Moneyline da Pinnacle

Há 837 mapas com moneyline point-in-time válida e nenhum snapshot posterior ao
cutoff. No desenvolvimento de 2025 Q3:

| Modelo | CRPS | Log Score | Cobertura 90% |
|---|---:|---:|---:|
| Liga + pace | 4,2713 | 3,4426 | 95,50% |
| Conjunto + moneyline quadrática | 4,3076 | 3,4867 | 97,23% |
| Melhor conjunto fundamental | 4,3446 | 3,4977 | 97,58% |

Em 2026, o híbrido teve CRPS 4,3898 contra 4,4100 do baseline, mas piorou o Log
Score de 3,4597 para 3,4722 e ficou superdisperso. O ganho não é confirmatório,
não passou os guardrails e não autoriza promoção.

## Verificação

- Testes R: todos passaram; um teste autenticado foi pulado porque a variável
  de ambiente da API não estava configurada nessa sessão.
- Testes Python: 22 passaram.
- PMFs, modelo dirigido, Beta-Binomial, moneyline, matching e integridade
  temporal passaram nos testes focados.
- A checagem direta do pacote sobre a raiz foi interrompida porque o R passou a
  varrer artefatos e dependências temporárias fora do pacote. A suíte completa
  de testes terminou sem falhas.

## Estado operacional

O Streamlit permanece com liga + pace. Os novos modelos não foram promovidos.
O próximo teste confirmatório continua sendo o registro prospectivo das paper
bets, com linha, odds, timestamp, previsão e resultado.
