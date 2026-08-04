# Prompt para revisão independente do modelo pré-draft de total de kills

Quero que você atue como um pesquisador quantitativo sênior especializado em
modelos probabilísticos, validação temporal, esports e mercados de apostas.
Faça uma revisão independente e rigorosa do projeto descrito abaixo.

Não quero concordância automática com nossas decisões. Procure erros de
formulação, leakage, seleção de modelo, backtest, calibração, dispersão,
targets, engenharia de variáveis e interpretação econômica. Quando sugerir
algo, explique o mecanismo causal ou estatístico esperado, os dados necessários
e como testar sem usar informação futura.

O modelo é exclusivamente pré-jogo, por mapa e antes do draft. Não podemos usar
campeões, composição, side, patch conhecido após o cutoff, resultado de mapas
anteriores da mesma série ou qualquer informação indisponível no instante da
previsão.

## 1. Objetivo do projeto

Queremos estimar a distribuição completa, PMF, do total de kills de um mapa de
League of Legends. A decisão operacional é apostar Over, Under ou não apostar
na linha `.5` oferecida por uma soft book.

A Pinnacle é usada como:

1. benchmark probabilístico;
2. referência de preço e futura medição de CLV;
3. possível prior para o total e para a força relativa das equipes.

A aposta real seria executada na melhor linha e odds soft encontradas
manualmente. Não queremos provar vantagem contra a Pinnacle como objetivo
final. Queremos usar o mercado mais eficiente como referência e procurar
desajustes maiores nas soft books.

O target fundamental é `total_kills_game`. A partir da PMF calculamos:

```text
P(Under linha .5) = soma PMF(k), k <= floor(linha)
P(Over linha .5)  = 1 - P(Under)
EV(lado)          = P(lado) * odd_decimal(lado) - 1
```

Usamos stake fixa de uma unidade na pesquisa econômica. Avaliamos EV mínimo de
0%, 3%, 5%, 8% e 10%, sem escolher automaticamente o threshold historicamente
mais lucrativo.

## 2. Modelo atualmente ativo

O modelo ativo no Streamlit é o `weekly_directed_raw`, bundle
`directed-ml-f30d7251717d`.

Snapshot atual do bundle:

- cutoff: 2026-07-28 20:25:33 UTC;
- 11.909 mapas no treinamento fundamental;
- 837 mapas na camada histórica de moneyline;
- theta atual: aproximadamente 19,0021;
- atualização pretendida: todo sábado, permanecendo congelado durante a semana.

Ele não é uma regressão única de total. Decompõe o mapa em duração e intensidade
de kills das duas equipes:

```text
log(D) ~ Normal(eta_duration, sigma_duration²)
rate_A  = exp(eta_A)
rate_B  = exp(eta_B)
mu(D)   = D * (rate_A + rate_B)
K | D   ~ NegativeBinomial(mean = mu(D), theta)
```

A PMF final integra a incerteza da duração com quadratura determinística.

Principais variáveis da duração:

- liga;
- pace histórico do confronto;
- nível e desequilíbrio de duração histórica;
- número do mapa.

Principais variáveis direcionadas de intensidade para cada equipe:

- KPM próprio na temporada;
- DPM cedido pelo adversário na temporada;
- KPM próprio nos últimos 15 mapas;
- DPM cedido pelo adversário nos últimos 15 mapas;
- liga, pace e número do mapa.

A moneyline Pinnacle é convertida para probabilidades sem vig. O modelo usa o
logit da probabilidade de vitória, desequilíbrio absoluto, termo quadrático e
interações para representar mapas equilibrados, favoritos moderados e favoritos
extremos.

Theta segue:

```text
Var(K | mu) = mu + mu² / theta
```

Ele é reestimado a cada bundle semanal. Em replays anteriores variou de 17,122
a 25,644, com mediana 20,372.

## 3. Contrato operacional atual do Streamlit

Inputs obrigatórios:

- liga, horário e número do mapa;
- equipes A e B;
- cinco titulares de cada equipe;
- moneyline Pinnacle das duas equipes;
- linha soft e odds Over/Under soft;
- quando disponível, linha e odds Over/Under do total Pinnacle.

Team totals Pinnacle são opcionais.

Regras de roster:

- uma troca de titular não bloqueia;
- duas ou mais trocas bloqueiam a confirmação da aposta até o novo roster
  completar cinco mapas;
- a previsão continua visível durante o bloqueio;
- mudança de organização ou nome com os mesmos cinco jogadores preserva o
  estado e não bloqueia;
- jogadores servem para continuidade do roster, não possuem rating individual.

O directed é o único modelo mostrado na interface. Challengers são calculados
ocultamente e registrados como paper bets. Registramos decisões automáticas por
threshold de EV separadamente das apostas realmente confirmadas pelo usuário.

## 4. Validação e correções de auditoria

O protocolo usa nove folds rolling-origin em 2023–2025. Treino, tuning,
shrinkage e escolha de hiperparâmetros devem ocorrer dentro de cada fold. O
bundle e os estados ficam congelados a cada sábado. O período de 2026 é apenas
diagnóstico e não pode selecionar modelo ou hiperparâmetro.

O backtest original do directed tinha 450 apostas, lucro de 41,017 unidades,
yield de 9,11% e drawdown máximo de 19,455 unidades. Ele era temporal, mas não
reproduzia exatamente o ritual de congelamento semanal.

Quando o modelo e todos os snapshots das equipes foram corretamente congelados
a cada sábado, o resultado passou para:

- 495 apostas;
- lucro de 21,109 unidades;
- yield de 4,26%;
- drawdown máximo de 15,436 unidades;
- Brier 0,247171;
- Log Loss 0,687368;
- zero violações temporais nos 723 mapas auditados.

Portanto, tratamos o retorno histórico como evidência exploratória, não como
prova de edge. Não temos soft odds históricas point-in-time confiáveis. Os
backtests econômicos com Pinnacle são benchmarks conservadores e não comprovam
retorno nas soft books.

Resultados originais por liga, EV maior que zero e stake de 1 unidade:

| Liga | Apostas | Lucro | Yield | Drawdown máximo |
|---|---:|---:|---:|---:|
| CBLOL | 33 | +3,280u | +9,94% | 3,194u |
| LCK | 132 | +7,866u | +5,96% | 8,814u |
| LCS | 51 | +6,868u | +13,47% | 4,685u |
| LEC | 75 | -4,243u | -5,66% | 11,558u |
| LES | 2 | +1,753u | +87,65% | 0u |
| LFL | 69 | +14,089u | +20,42% | 5,083u |
| LPL | 88 | +11,404u | +12,96% | 4,922u |
| Geral | 450 | +41,017u | +9,11% | 19,455u |

LES não é interpretável com apenas duas apostas. A LEC já era a única liga
grande negativa. Em 2026 secundário, a LEC teve 56 apostas, -2,032 unidades,
yield de -3,63% e drawdown de 7,258 unidades.

Também corrigimos uma auditoria que inicialmente dizia não haver moneylines
timestampadas. O banco possui 140.768 snapshots com `odds_timestamp`. O erro
estava no campo usado para reconstruir o fechamento do mapa.

Cobertura estrita do último snapshot entre T-45 e T-30:

- total Pinnacle: 946 mapas de desenvolvimento e 1.096 mapas de 2026, sete
  ligas;
- moneyline Pinnacle: 432 mapas, seis ligas;
- team totals completos: 697 mapas, sete ligas;
- total mais moneyline: 411 mapas;
- total, moneyline e previsão directed semanal: 321 mapas.

Nosso gate pré-registrado exige pelo menos 500 mapas e três ligas para modelos
informados pelo total/moneyline. Logo, a camada conjunta ainda está abaixo do
gate, embora possa ser estudada e acompanhada prospectivamente.

## 5. Experimentos realizados

### Pinnacle como prior do total

Testamos:

```text
log(mu_final) = log(mu_Pinnacle)
              + w * (log(mu_directed) - log(mu_Pinnacle))
```

Nos 217 mapas de desenvolvimento com interseção completa:

- directed, `w = 1`: Brier 0,23963; Log Loss 0,67142;
- Pinnacle pura, `w = 0`: Brier 0,24879; Log Loss 0,69072;
- qualquer peso adicional dado ao total Pinnacle piorou o directed;
- portanto o ótimo no desenvolvimento foi 100% directed.

Em 338 mapas diagnósticos de 2026, pesos de 0,6 a 0,7 ficaram ligeiramente
melhores. Um candidato com 70% directed, 30% Pinnacle e theta multiplicado por
0,75 teve:

- Brier 0,24753 contra 0,24842 do directed;
- Log Loss 0,68816 contra 0,69014;
- probabilidade bootstrap de melhora de apenas 70,85% e 71,5%;
- pior Count Log Score;
- cobertura de 90% de 93,79%, acima do teto de 93%;
- piora na LEC e na LCS;
- piora geral no desenvolvimento.

Não promovemos. Um blend mais conservador, 70% directed e 30% Pinnacle usando o
theta semanal normal, ficou em shadow apenas para paper betting prospectivo.

### Dispersão

No desenvolvimento, multiplicar theta por 1,5 reduziu a cobertura de 94,47%
para 92,17% e melhorou levemente CRPS e Log Score. Em 2026 a mesma alteração
piorou Brier, Log Loss, Count Log Score e CRPS. Mantivemos o theta semanal sem
multiplicador fixo.

Theta global móvel, theta por liga com pooling e liga por regime já foram
testados anteriormente. Nenhuma versão apresentou ganho temporal robusto. A
etapa por time foi interrompida para evitar variância e sobreajuste.

### Team totals

Testamos a soma implícita dos team totals versus o total geral, participação
relativa A/B, diferença de soma e pooling por liga. Todas as correções pioraram
Brier e Log Loss no desenvolvimento e em 2026.

Mantivemos team totals apenas como diagnóstico e possível alocação relativa de
kills, não como correção da média total.

### Estados dinâmicos

Refizemos a comparação sem draft, campeões, side ou patch em 7.586 mapas nos
nove folds.

O melhor bloco foi ratings mais momentum:

- CRPS 4,60642;
- Log Score 3,50523;
- 97,2% de probabilidade bootstrap de superar a base dinâmica.

Entretanto, permaneceu pior que o fundamental simples de referência:

- CRPS 4,56215;
- Log Score 3,49243.

Por isso os estados dinâmicos não foram promovidos.

### Duração

Entre os candidatos válidos pré-draft, a lognormal regularizada com pace e
históricos temporais continua melhor:

- 7.586 mapas;
- CRPS 3,05275;
- Log Score 3,10002;
- MAE de 4,323 minutos.

Alguns challengers antigos aparentemente melhores usavam draft e foram
excluídos. A mistura lognormal condicionada ao possível vencedor foi
implementada, mas está em HOLD porque a amostra estrita de moneyline possui 432
mapas, abaixo do gate de 500.

### Calibração e regime

Já testamos correções globais, liga com pooling, liga por split/regime, janelas
de 30/60/90 dias, Platt, Beta e regressão logística com offset de mercado.
Nenhuma apresentou estabilidade suficiente. Modelos puramente logísticos
ficam apenas como diagnóstico porque precisamos de uma PMF completa.

## 6. Critérios de promoção

As métricas primárias são Brier e Log Loss nas linhas reais. Exigimos:

- probabilidade bootstrap acima de 95% de melhora em pelo menos uma, sem piora
  da outra;
- erro de calibração sem aumento superior a um ponto percentual;
- nenhuma liga com pelo menos 100 mapas piorando Brier ou Log Loss em mais de
  1%;
- CRPS e Count Log Score da PMF sem piora superior a 0,5%;
- cobertura do intervalo de 90% entre 87% e 93%;
- preferência pelo modelo mais simples dentro de um erro-padrão do melhor.

Bootstrap pareado por mês e série, com 2.000 réplicas.

## 7. Decisão atual

O melhor modelo validado e operacional continua sendo o
`weekly_directed_raw`. Não afirmamos que ele seja teoricamente o melhor modelo
possível; afirmamos que é o melhor entre os candidatos testados sob o protocolo
atual.

No Streamlit:

- directed semanal é a previsão visível;
- `market_implied_nb_exact`, híbrido Poisson/NB e
  `market_directed_blend_w070` rodam ocultamente;
- cada challenger salva PMF, probabilidades, diagnóstico e paper decisions nas
  faixas de EV;
- apostas confirmadas pelo usuário são registradas separadamente;
- duas ou mais trocas de titulares bloqueiam ação até cinco mapas.

## 8. O que quero que você revise

Responda como um revisor independente. Estruture sua resposta nas seções
abaixo.

### A. Diagnóstico do modelo atual

1. A decomposição duração × intensidade × Binomial Negativa é adequada para o
   fenômeno?
2. Há problemas de identificabilidade entre duração e intensidade?
3. O target e a forma de transformar a PMF em probabilidade na linha estão
   corretos?
4. A moneyline está sendo usada da forma certa?
5. Você manteria o directed como modelo ativo diante das evidências?

### B. O que você faria diferente

Proponha uma arquitetura alternativa concreta. Diga exatamente:

- distribuição;
- função de ligação;
- componentes e interações;
- regularização ou pooling;
- tratamento temporal;
- tratamento de equipes novas e troca de roster;
- forma de produzir a PMF;
- forma de calibrar probabilidades nas linhas;
- como integrar Pinnacle sem simplesmente copiar a linha.

Compare sua proposta com o directed em complexidade, interpretabilidade,
risco de leakage e tamanho de amostra necessário.

### C. Novas variáveis pré-jogo

Sugira variáveis disponíveis antes do draft e antes do primeiro mapa da série.
Para cada variável, informe:

1. definição exata;
2. mecanismo esperado sobre kills ou duração;
3. fonte possível;
4. instante em que fica disponível;
5. risco de leakage;
6. transformação sugerida;
7. pooling ou shrinkage necessário;
8. ablação necessária para provar valor incremental.

Considere, entre outras possibilidades:

- dano causado e recebido por minuto;
- kills e conflito até 10/15 minutos;
- ouro e XP por minuto e aos 10/15 minutos;
- comportamento quando à frente ou atrás;
- capacidade de fechar, estender ou virar jogos;
- concentração de estilo por roster;
- tempo de inatividade e incerteza;
- mudanças de organização com roster preservado;
- força do calendário e qualidade dos adversários;
- formato da série e mapa da série, sem usar resultados intrassérie;
- viagens, região, online/LAN e mudança de competição, se houver dados
  confiáveis antes do mapa;
- divergências entre moneyline, total geral, team totals e modelo fundamental;
- movimentos de preço e inclinação temporal do mercado, usando apenas snapshots
  anteriores ao cutoff.

Não inclua draft, campeão, side, patch posterior ao cutoff ou resultados de
mapas anteriores da mesma série.

### D. Modelos e métodos estatísticos

Avalie criticamente se vale testar:

- Negative Binomial hierárquica com efeitos dinâmicos;
- generalized additive models;
- state-space models e dynamic GLMs;
- hurdle ou mistura de regimes para stomps e jogos longos;
- distribuição COM-Poisson, generalized Poisson ou Poisson-lognormal;
- modelos conjuntos de duração, vencedor e kills;
- survival analysis para duração;
- stacking ou Bayesian model averaging regularizado;
- conformal calibration para intervalos discretos;
- isotonic/Platt/Beta apenas para diagnóstico de linha;
- market residual model com offset da Pinnacle;
- modelos separados por liga com partial pooling;
- modelos por time com shrinkage forte;
- detecção explícita de drift e change points.

Não apenas liste métodos. Diga quais três você priorizaria, quais rejeitaria e
por quê, considerando nossa amostra e o risco de overfitting.

### E. Validação

Revise os nove folds, o freeze aos sábados, o uso diagnóstico de 2026, o
bootstrap e os gates. Procure:

- leakage temporal;
- seleção repetida de hipóteses;
- viés de sobrevivência de ligas/equipes;
- matching incorreto de mercados;
- diferenças entre horário agendado e início real;
- uso acidental de closing line;
- dependência entre mapas da mesma série;
- problemas na comparação de linhas diferentes;
- múltiplas apostas derivadas do mesmo mapa;
- vieses causados por ausência seletiva de odds.

Proponha um protocolo melhor se necessário.

### F. Mercado e decisão de aposta

Explique como usar Pinnacle como benchmark sem eliminar justamente o edge que
queremos encontrar nas soft books. Discuta:

- prior de mercado versus feature;
- line shopping;
- comparação quando a linha soft difere da Pinnacle;
- remoção de vig;
- CLV;
- margem de segurança;
- erro de estimação do EV;
- stake fixa versus Kelly fracionado;
- abstention;
- limites mínimos de amostra prospectiva antes de apostar dinheiro real.

### G. Plano experimental priorizado

Entregue uma tabela com no máximo dez experimentos, ordenados por prioridade.
Para cada um, inclua:

- hipótese;
- mudança mínima;
- dados exigidos;
- baseline;
- métricas primárias;
- gate de aprovação;
- risco de leakage;
- custo de implementação;
- decisão GO, GO WITH CONDITIONS, HOLD ou NO-GO.

### H. Veredito

Finalize respondendo diretamente:

1. Qual modelo você usaria hoje para as apostas?
2. O que você mudaria imediatamente no modelo ativo?
3. O que manteria apenas em paper betting?
4. Qual é a maior fragilidade metodológica atual?
5. Qual experimento possui maior chance de produzir ganho real?
6. Existe alguma conclusão nossa que você considera incorreta ou forte demais?

Se algum dado necessário não foi fornecido, diga exatamente o que falta. Não
preencha lacunas com suposições silenciosas e não use ROI histórico isolado
como evidência de qualidade preditiva.
