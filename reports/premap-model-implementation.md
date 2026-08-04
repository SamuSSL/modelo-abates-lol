# Modelo pré-mapa de abates

## Estado da implementação

O pipeline foi implementado em três camadas separadas:

1. fundamental multiplicativa, sem odds;
2. fundamental com moneyline sem vig;
3. fundamental com moneyline e mercado de total de kills.

Draft e campeões não entram nas novas camadas. Streamlit, API pública e bundle
operacional não foram alterados.

Os ratings são calculados point-in-time para temporada, split, últimos 15,
10 e 5 mapas. Há dois artefatos: um congelado antes da série e outro com
cutoff próprio 15 minutos antes de cada mapa. Resultados só ficam disponíveis
depois do horário do mapa, duração observada e margem adicional de cinco
minutos. Os dois artefatos têm 11.883 mapas-alvo.

O DuckDB e os arquivos Parquet foram reconciliados com os RDS. Há 13.770 mapas
canônicos e 27.540 registros equipe-mapa em cada formato.

## Resultado do desenvolvimento de 2023 a 2025

Foram usados os nove folds rolling-origin já registrados.

| Modelo | CRPS | Log Score |
|---|---:|---:|
| Ensemble-sombra atual | 4,5401 | 3,4884 |
| V1 atual | 4,5622 | 3,4924 |
| Liga + pace | 4,5861 | 3,4981 |
| Melhor multiplicativo, rate com expoentes regularizados | 4,6159 | 3,5071 |
| Melhor fórmula direta count | 4,6238 | 3,5092 |

As fórmulas multiplicativas não superaram as referências. Na ablação
regularizada, `pace + rate_last15` foi o melhor bloco de ratios, mas o ganho
contra o Ridge com apenas `pace` foi de aproximadamente 0,011 de CRPS e todos
os candidatos ficaram dentro de um erro-padrão. Pela regra do menor modelo
equivalente, a seleção foi apenas `pace`.

Portanto, os ratios permanecem disponíveis como pesquisa e diagnóstico, mas
não justificam entrar no modelo mínimo neste momento. O modelo fundamental
viável sem draft continua sendo `liga + pace`. Considerando todas as versões
existentes, V1 permanece a escolha simples aprovada; a sombra ainda não pode
ser promovida porque está em confirmação prospectiva.

## Duração

| Modelo | CRPS | Log Score | MAE | Cobertura 90% |
|---|---:|---:|---:|---:|
| Lognormal regularizada | 3,0527 | 3,1000 | 4,3234 min | 89,40% |
| Lognormal | 3,0642 | 3,1053 | 4,3276 min | 89,39% |
| Gamma | 3,0713 | 3,1152 | 4,3342 min | 90,32% |

A lognormal regularizada foi a melhor distribuição de duração. A diferença
de CRPS contra a lognormal simples foi 0,0108, com erro-padrão pareado de
0,0054 entre folds. Ela é o candidato de duração para a etapa de mercado.

## Moneyline e total de kills

As fixtures brutas permitiram formar 1.283 pares únicos verificados entre
eventos `Kills` e `Regular`. Dois pares ficaram ambíguos e um não teve
correspondente dentro da tolerância; os três estão excluídos até revisão.

O esquema, coletor retomável, teste de contrato, seleção T-15 a T-30,
orientação home/away, probabilidades sem vig, faixas de favoritismo,
modelos informados pelo mercado e backtest de softs estão implementados.

A coleta autenticada de moneyline não foi executada porque
`BETTINGISCOOL_API_KEY` não está definida no processo atual. Por isso ainda
não há resultado honesto para dizer se moneyline ou total da Pinnacle melhora
o modelo, nem para afirmar vantagem contra casas soft.

## Decisão atual

- Manter V1 como modelo simples operacional existente.
- Para uma versão estritamente sem draft, usar `liga + pace`.
- Não acrescentar os ratios ao modelo mínimo por enquanto.
- Usar lognormal regularizada para duração na próxima avaliação.
- Não promover nenhuma camada de mercado antes do backfill e dos folds
  históricos, seguidos de confirmação prospectiva.

## Atualização dirigida e moneyline de 2026-07-30

Esta seção substitui o estado operacional descrito acima para a rodada
pré-mapa sem draft. O backfill autenticado e o pareamento independente de
moneyline foram concluídos. A auditoria de 182 janelas em 13 competições não
encontrou fixtures anteriores a maio de 2025 para os IDs do manifesto.

Foram obtidos 837 mapas com moneyline point-in-time, sem snapshots posteriores
ao cutoff. O modelo dirigido passou a prever duração separadamente, intensidades
de cada equipe contra a concessão adversária, total por Binomial Negativa e
divisão por Beta-Binomial. A moneyline sem vig foi usada de forma contínua em
todo o espectro de favoritismo.

No desenvolvimento de 2025 Q3, `liga + pace` obteve CRPS 4,2713 e Log Score
3,4426. O melhor modelo dirigido com moneyline obteve 4,3069 e 3,4865. O
bootstrap da diferença de CRPS foi +0,0356, com intervalo de 95% de -0,0603 a
+0,1339. A dispersão condicional não acrescentou sinal e foi simplificada para
dispersão global.

A decisão é manter `liga + pace` no Streamlit e deixar o modelo dirigido
apenas como challenger de pesquisa. O relatório completo está em
`artifacts/premap_joint_model/implementation_report.md`.
