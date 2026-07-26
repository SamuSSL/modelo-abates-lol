# Especificação de avaliação

## Revisão para promoção da V1

Antes de abrir 2026, os critérios foram congelados em
`config/promotion.yml`. O candidato primário é `nb_pace_draft`, comparado
com `nb_pace`. Se falhar, o único fallback permitido é `nb_pace`,
comparado com `nb_league`.

Para promover, o candidato precisa ter CRPS geral igual ou menor que a
referência, cobertura de 90% entre 87% e 93%, erro médio absoluto menor
ou igual a uma kill, PMFs finitas e nenhuma liga com degradação de CRPS
maior que 0,10. Se primário e fallback falharem, a V1 não libera
previsões para aposta.

## Objetivo

Medir generalização temporal, calibração e utilidade probabilística sem usar odds históricas inexistentes como evidência econômica.

## Particionamento temporal

### Rodada simples de indicadores de equipe

A comparação pré-registrada usa os nove blocos trimestrais de 2023–2025 já
definidos para o estudo de recência. Cada fold treina apenas com séries cujo
cutoff seja anterior ao início da validação. O treino começa em 2022 e recebe
pesos exponenciais com meia-vida de 60 dias. O ano de 2026 não é lido para
ajuste, seleção, ablação ou decisão desta rodada.

Todos os candidatos devem prever exatamente os mesmos mapas. Comparações usam
CRPS pareado por mapa e bootstrap por blocos semanais. Também são reportados
Log Score, erro médio, coberturas de 50%, 80% e 90%, resultado por fold e por
liga. A referência primária é `empirical_league`; cada modelo aninhado também
é comparado ao antecessor imediato.

Ordem das ablações:

1. distribuição de contagem: Poisson contra Negative Binomial;
2. ritmo histórico combinado;
3. ataque e exposição defensiva;
4. dano causado e dano recebido.

Nenhum limiar de promoção é criado depois de olhar os resultados. Nesta rodada,
ganho incerto mantém o modelo mais simples. Uma piora com intervalo temporal
inteiro acima de zero elimina o bloco.

### Desenvolvimento

Usar rolling-origin validation com blocos cronológicos. Em cada fold:

1. treino contém apenas séries encerradas antes do início do bloco de validação;
2. preprocessamento, aliases supervisionados, encodings, shrinkage e tuning são ajustados novamente no treino;
3. todas as features de uma série usam o cutoff anterior ao primeiro mapa;
4. validação contém um bloco futuro contíguo;
5. previsões são armazenadas no nível do mapa.

A duração dos blocos será escolhida antes dos experimentos finais para garantir:

- presença das ligas-alvo quando o calendário permitir;
- amostra suficiente por bloco;
- mais de uma mudança de meta ao longo dos folds;
- custo computacional viável.

Se uma liga não tiver jogos em um bloco, isso será registrado; não haverá imputação de resultados.

### Holdout final

O período cronológico mais recente com cobertura suficiente será isolado antes de tuning. Ele só será aberto depois que:

- candidatos e hiperparâmetros estiverem congelados;
- janela histórica estiver escolhida;
- feature catalog estiver congelado;
- critérios de promoção estiverem registrados.

## Métrica primária

CRPS discreto médio por mapa.

Comparações usam diferenças pareadas por mapa. Incerteza será estimada por bootstrap em blocos temporais ou séries, preservando dependência local.

## Guardrails

### Distribuição

- Log Score;
- randomized PIT;
- histograma PIT e desvios de uniformidade;
- cobertura de intervalos de 50%, 80% e 90%;
- sharpness;
- erro de média e mediana;
- quantile loss.

### Calibração Over/Under

Para uma grade de linhas `.5` determinada pela faixa observada no treino:

- Brier Score;
- Log Loss;
- calibração observada versus prevista;
- intercepto e slope de calibração;
- contagem efetiva de mapas;
- confiabilidade por bins com intervalos.

Linhas do mesmo mapa não serão tratadas como observações independentes em intervalos ou testes.

### Segmentos

- liga;
- temporada;
- patch apenas como diagnóstico;
- side;
- fase regular/playoffs apenas como diagnóstico;
- faixa da linha;
- faixa de total esperado;
- tamanho de amostra de equipe, jogador e campeão;
- confiança do arquétipo;
- drift e tempo desde o cutoff de treino.

## Baselines e comparações

Todo candidato será comparado ao melhor dos três baselines no mesmo conjunto de mapas.

Relatar:

- diferença absoluta e relativa de CRPS;
- intervalo de confiança do bootstrap temporal;
- diferença de Log Score;
- calibração global e por liga;
- latência, memória e tempo de treino;
- falhas ou folds incompletos;
- resultado das ablações.

P-valores, quando usados, serão secundários a tamanho de efeito, intervalo e relevância prática.

## Ablações obrigatórias

Partindo da configuração elegível mais simples:

- remover jogadores;
- remover campeões individuais;
- remover atributos e arquétipos;
- remover estabilidade de lineup;
- remover efeitos de side;
- remover ajuste de adversário;
- comparar sem e com submodelo de duração;
- comparar total direto e placares por equipe;
- comparar pooling parcial e modelos separados por liga;
- comparar janela fixa e recência exponencial.

Uma feature ou módulo complexo sem ganho estável será removido do campeão, mesmo que melhore um fold isolado.

## Definição de amostra mínima

### Sensibilidade do shrinkage de equipe

Antes de calcular os resultados, foi congelada a comparação de priors
equivalentes a 10, 20, 50 e 100 jogos. Todos usam o candidato `nb_pace`, os
mesmos nove folds de 2023–2025 e meia-vida de 60 dias nas features e nos pesos
do treino. O holdout de 2026 permanece fechado.

Cada prior representa quanta evidência média da liga é misturada ao histórico
da equipe. Quanto maior o prior, menos um período curto e extremo consegue
deslocar a projeção.

CRPS define a ordenação. Log Score, coberturas, resultado por liga e fold e
bootstrap semanal funcionam como guardrails. Se candidatos ficarem
estatisticamente empatados, a regra pré-registrada prefere shrinkage mais forte,
pois reduz reação a amostras pequenas.

### Limite mínimo de histórico de equipe

O limite usa jogos efetivos com decaimento, não apenas contagem bruta. Um jogo
antigo vale menos que um jogo recente. A métrica operacional é o menor histórico
efetivo entre as duas equipes para `combined_kills_per_minute`.

Sem consultar os resultados, a distribuição de cobertura definiu a grade de 1,
2, 3, 5, 8, 10, 12, 15, 20, 25 e 30 jogos efetivos. Contagens brutas de 1, 3,
5, 10 e 20 jogos serão apenas diagnóstico.

Para cada corte serão formados dois grupos:

1. elegíveis, com ambas as equipes no corte ou acima;
2. bloqueados, com pelo menos uma equipe abaixo do corte.

O sinal `nb_pace` será comparado ao `nb_league` nos mesmos mapas por CRPS
pareado e bootstrap semanal. O menor corte só pode ser recomendado quando o
sinal melhora de forma confiável no grupo elegível e ainda não melhora de forma
confiável no grupo bloqueado. Se nenhum corte produzir essa separação, nenhum
limite será inventado com base apenas nesta análise.

Também serão reportados Log Score, cobertura de 90%, mapas retidos, resultado
por liga e distribuição das amostras. O holdout de 2026 permanece fechado.

Para equipe, jogador e versão de campeão:

1. gerar previsões out-of-fold agrupadas por contagem histórica disponível;
2. avaliar CRPS, calibração, erro e largura por faixas crescentes;
3. identificar o menor ponto em que desempenho e calibração deixam de ser materialmente instáveis;
4. verificar cobertura resultante por liga;
5. propor limites separados por entidade;
6. registrar proposta e evidência no decision log;
7. exigir aprovação antes de ativar bloqueios em produção.

Não será escolhido limite usando o holdout final.

## Gate de calibração

Os limites numéricos serão propostos depois dos folds de desenvolvimento, antes de abrir o holdout. A proposta deve incluir:

- variação do melhor baseline;
- incerteza amostral;
- slope e intercepto globais e por liga;
- cobertura dos intervalos;
- linhas com amostra suficiente;
- tolerância de degradação por liga.

Alterar o gate depois de ver o holdout invalida a avaliação e exige novo holdout futuro.

## Protocolo da rodada estrutural e bayesiana

As decisões usam exclusivamente mapas anteriores a 2026. Os folds trimestrais
de 2023–2025 continuam sendo a unidade de validação; mapas de 2022 formam o
histórico inicial. Em cada fold, duração, intensidade, shrinkage, taxonomia
derivada de dados, discretização, PCA e tuning de machine learning são
reajustados sem observar o bloco futuro.

O ano de 2026 não participa de seleção, tuning, escolha de features, escolha de
prior, calibração ou ensemble. Depois do congelamento, ele pode ser executado
uma única vez como comparação secundária rotulada como já conhecida durante o
desenvolvimento do projeto. Não será chamado de confirmação final.

O cutoff prospectivo é a maior data de resultado presente no manifesto no
momento do congelamento. Somente mapas recebidos depois desse cutoff compõem a
confirmação limpa.

Além de CRPS, Log Score, Brier e calibração, a decomposição deve reportar:

- erro e cobertura da duração;
- erro e calibração da intensidade por minuto;
- correlação residual entre duração e intensidade;
- contribuição da incerteza de duração para a largura da PMF;
- ablação dos efeitos de equipe, adversário, arquétipo e jogador–campeão.

> Decisão posterior: avaliações e ablações de jogador são históricas e ficaram
> arquivadas. A avaliação operacional usa somente equipe e draft; identidade,
> amostra e interação de jogador não são elegíveis para promoção.

O Bayes só é elegível quando todas as chains apresentam R-hat aceitável, ESS
suficiente, zero divergências materiais, tree depth controlado e posterior
predictive checks coerentes. Se os diagnósticos falharem, aumentar iterações
sozinho não constitui correção.

## Gate de promoção

O candidato só pode receber `promotion_status = "production"` quando:

- a estimativa pontual de CRPS supera o melhor baseline no desenvolvimento e holdout;
- o intervalo bootstrap não sustenta uma degradação material;
- os limites aprovados de calibração são atendidos;
- nenhuma liga apresenta degradação material sem warning ou bloqueio operacional;
- todas as probabilidades são válidas;
- todos os testes críticos passam;
- inferência fica abaixo de 30 segundos;
- o resultado é reproduzível em ambiente restaurado.

Caso contrário, o status será `rejected` ou `research`, acompanhado dos motivos.

## Avaliação prospectiva

### Todas as consultas

Avaliar:

- calibração;
- CRPS e Log Score quando a PMF integral estiver salva;
- movimento de linha entre snapshots do mesmo evento;
- diferença entre modelo e probabilidade implícita sem vig quando ambas as odds existirem.

### Apostas confirmadas

Para stake fixa de 1 unidade:

```text
profit_win = decimal_odds - 1
profit_loss = -1
profit_void = 0
ROI = sum(profit) / number_of_settled_bets
```

Relatar Over e Under separadamente, além do agregado. Consultas sem `bet_side` nunca entram no ROI.

Sem bookmaker, não haverá análise por casa nem afirmações sobre closing line específica de uma casa.

## Relatórios

- `reports/eda.html`;
- `reports/feature-association.html`;
- `reports/model-comparison.html`;
- `reports/calibration.html`;
- `reports/drift.html`;
- tabelas de métricas por fold e por mapa em artefatos machine-readable.

## Reprodutibilidade

Cada execução de avaliação registra:

- hashes de dados e configuração;
- versão de cada candidato;
- seeds;
- folds;
- ambiente `renv`;
- warnings;
- duração;
- métricas brutas e agregadas.
