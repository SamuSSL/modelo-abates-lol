# Especificação de modelagem

## Objetivo estatístico

Estimar uma PMF calibrada para o total inteiro de kills de um mapa, condicionada apenas a informações disponíveis no cutoff pré-série.

O melhor modelo não será escolhido por MAE isolado. CRPS fora da amostra será a métrica primária, sujeita aos guardrails de calibração, Log Score, estabilidade por liga e custo operacional.

## Filosofia

- Começar pelo modelo mais simples capaz de representar dispersão.
- Manter um conjunto pequeno de features com interpretação operacional.
- Exigir ablação para cada grupo adicional.
- Não promover complexidade por ganho marginal instável.
- Separar qualidade estatística de rentabilidade de mercado.

## Universo inicial de features

### Contexto

- liga canônica;
- side;
- temporada como índice temporal apenas quando necessária ao adapter;
- recência contínua;
- força relativa histórica.

Patch, playoffs, bans, ordem de draft, first pick e odds são proibidos como features.

### Equipes

- kills por minuto e deaths permitidas por minuto em janelas anteriores;
- total de kills por minuto dos mapas anteriores;
- média e dispersão de duração histórica;
- taxas de mapas acima de linhas calculadas apenas no fold de treino;
- tendência recente e tamanho efetivo de amostra;
- ataque e defesa com shrinkage por liga e qualidade do adversário;
- efeitos por side quando suportados;
- estabilidade da escalação.

Médias brutas sem shrinkage não podem ser a única medida de força.

### Jogadores

Identidades, ratings, estabilidade de elenco e interações de jogadores não
entram no modelo nem no contrato de inferência. As linhas de jogador da fonte
permanecem apenas para validar o target e identificar os campeões escolhidos.

### Campeões e composição

- frequência histórica do campeão para proteção de cobertura;
- atributos funcionais versionados;
- scores agregados da composição;
- arquétipos primário e secundário;
- complementaridade, redundância e cobertura funcional.

Interações de campeão de alta cardinalidade não entram sem regularização e ganho comprovado.

## Taxonomia funcional

### Regra aprovada para a V1

A V1 usa uma única taxonomia estática de 2026 para todos os mapas de
2022–2026. Reworks e versões históricas de campeão não serão tratados.

A lista de campeões vem dos dados locais de 2026 e é complementada por campeões
observados em 2022–2025. Atributos descrevem o kit e identidade funcional
vigentes em 2026. Resultados competitivos de 2026 não podem ser usados para
calcular features aplicadas aos folds históricos, pois isso introduziria
informação futura. Dados de partidas de 2026 servem apenas para cobertura do
catálogo e auditoria enquanto o holdout estiver selado.

Cada campeão possui um único registro YAML, uma versão global da taxonomia,
fontes e justificativa. Campeão ausente ou sem cobertura mínima bloqueia a
inferência.

Para manter simplicidade, a primeira taxonomia usa poucos atributos observáveis:

```text
engage
disengage
pick
poke
frontline
protect
scaling
early_pressure
mobility
crowd_control
global_pressure
```

Novos atributos só entram quando necessários para distinguir composições e
quando passam em ablação temporal.

Cada campeão terá scores normalizados em atributos como:

```text
engage
disengage
dive
pick
poke
siege
frontline
protect
scaling
early_pressure
skirmish
split_push
wave_clear
mobility
crowd_control
global_pressure
damage_physical
damage_magic
execution_difficulty
snowball_dependency
```

A lista final será fechada após pesquisa e revisão. Cada registro deve conter versão, período de validade, fontes, justificativa e status de aprovação.

O classificador de composição:

1. agrega os cinco vetores respeitando posição;
2. calcula cobertura e complementaridade;
3. aplica regras versionadas e transparentes;
4. retorna todos os scores;
5. escolhe rótulos primário e secundário;
6. calcula confiança pela separação entre scores, cobertura da taxonomia e estabilidade das regras.

Arquétipos só entram no modelo preditivo após ablação temporal.

## Janelas históricas

O mesmo conjunto de folds comparará:

- 12, 18, 24 e 36 meses;
- temporada atual;
- temporada atual mais anterior;
- todo o período desde 2022;
- decaimento exponencial em grades pré-registradas de meia-vida.

Não será escolhida janela olhando o holdout final. O vencedor será selecionado nos folds de desenvolvimento por CRPS e guardrails.

## Candidatos obrigatórios

### Primeira rodada preditiva de indicadores de equipe

Antes de calcular qualquer score, a primeira rodada foi congelada em
`config/evaluation.yml`. Ela usa os nove folds de 2023–2025, histórico iniciado
em 2022, meia-vida de 60 dias e mantém 2026 selado.

Os candidatos são aninhados:

1. `empirical_league`: distribuição empírica por liga com shrinkage;
2. `poisson_league`: Poisson apenas com liga, como diagnóstico de dispersão;
3. `nb_league`: Negative Binomial apenas com liga;
4. `nb_pace`: adiciona ritmo histórico combinado das duas equipes;
5. `nb_attack_defense`: adiciona ataque e exposição defensiva;
6. `nb_pressure`: adiciona dano causado e dano recebido.

Durante o teste estrutural anterior aos scores, foi confirmada a identidade
`ritmo = (ataque + exposição defensiva) / 2`. Para evitar duplicar exatamente a
mesma informação, `nb_attack_defense` usa ritmo mais o balanço entre ataque e
exposição defensiva. Isso preserva a decomposição pretendida sem colinearidade.

As variáveis numéricas são simétricas entre Blue e Red, pois o target é o total
do mapa, e são padronizadas usando somente o treino de cada fold. A duração
observada, patch, playoffs, bans e ordem do draft não entram. Pesos do treino
decaem com meia-vida de 60 dias. As próprias features de equipe também são
calculadas com meia-vida de 60 dias e shrinkage de 20 jogos, ainda em status de
pesquisa.

Cada bloco só permanece se reduzir CRPS fora da amostra, preservar Log Score e
calibração e não esconder piora material por liga. Coeficientes plausíveis sem
ganho preditivo não bastam.

### Baselines

1. distribuição empírica global;
2. distribuição empírica por liga com shrinkage;
3. média móvel por liga convertida em distribuição com dispersão estimada apenas no treino.

### Modelos de contagem

4. Poisson GLM;
5. Negative Binomial GLM;
6. Negative Binomial com pooling parcial por liga, equipe e adversário.

Quasi-Poisson é apenas diagnóstico. Conway-Maxwell-Poisson, hurdle e zero-inflated só serão experimentados se dispersão ou zeros mostrarem necessidade.

### Modelo bayesiano

7. Negative Binomial hierárquico com pooling parcial.

O primeiro modelo bayesiano usa poucos efeitos e priors regularizadores. Deve apresentar prior predictive checks, R-hat, ESS, divergências, tree depth, posterior predictive checks e sensibilidade a priors. Execução pode durar até 12 horas.

### Gradient boosting

8. Challenger de boosting para média ou parâmetros da distribuição, com regularização, early stopping e validação estritamente temporal.

Ele não poderá produzir uma PMF por uma aproximação não validada. A conversão em distribuição deve ser documentada e calibrada nos folds.

### Ensemble

9. Ensemble probabilístico linear de candidatos elegíveis.

Pesos são aprendidos apenas nos folds de desenvolvimento, restringidos a valores não negativos que somem 1. Ensemble só será mantido se melhorar CRPS e guardrails além da variação amostral.

## Challengers estruturais

### Duração

Comparar pelo menos Gamma e log-normal para a duração. O submodelo retorna distribuição, nunca a duração observada. A arquitetura `intensidade × duração prevista` compete com o modelo direto e não é obrigatória.

### Placar por equipe

Comparar o total direto com duas intensidades de equipe simuladas conjuntamente. Dependência residual será medida antes de adicionar bivariado, Poisson-lognormal ou copula.

Modelos conjuntos só avançam se melhorarem a distribuição do total, não apenas os placares individuais.

## Regularização e entidades novas

Para a V1, a regra de rework abaixo está substituída pela taxonomia estática de
2026. Não haverá reinício de cobertura por versão histórica de campeão.

- Efeitos de baixa amostra usam shrinkage durante o treinamento.
- Apesar do shrinkage, a inferência operacional bloqueia equipe ou campeão
  abaixo dos mínimos aprovados.
- Rebranding mantém continuidade apenas quando o mapeamento de ID for confiável.
- Rework material cria versão nova do campeão e reinicia sua contagem de cobertura operacional.

## PMF e cauda

Cada modelo deve oferecer uma função que produza `P(Y = k)` para `k = 0...K`. `K` cresce até a massa residual estimada ficar abaixo da tolerância configurada. Depois, a PMF é normalizada e a massa truncada é registrada.

Não é permitido:

- truncar em uma linha fixa sem medir massa residual;
- calibrar cada linha Over separadamente de forma que a CDF deixe de ser monotônica;
- gerar probabilidades negativas ou não finitas.

## Calibração

Primeiro será preferido um modelo nativamente calibrado. Recalibração pós-hoc só pode usar previsões out-of-fold e deve preservar monotonicidade da CDF.

Calibradores possíveis serão avaliados no nível da distribuição ou CDF. Nenhum calibrador vê o holdout final durante seleção.

## Promoção

Um candidato é elegível quando:

- passa todos os testes de leakage e reprodutibilidade;
- possui PMF válida;
- conclui todos os folds previstos;
- atende diagnósticos próprios;
- não excede 30 segundos por inferência no hardware-alvo.

Ele só vira campeão quando:

- melhora CRPS contra o melhor baseline nos folds e no holdout;
- não piora materialmente Log Score ou calibração;
- não esconde degradação material em uma liga;
- o ganho persiste no bootstrap temporal;
- sua complexidade é justificada por ablação.

Se nenhum candidato atender, nenhum artefato recebe status de produção.

## Artefato do modelo

O bundle imutável deve conter:

```text
model object
preprocessing objects
feature schema
entity catalogs
minimum sample thresholds
taxonomy version
training cutoff
data hashes
model version
seed
PMF tail tolerance
evaluation summary
promotion status
```

## Rodada estrutural pós-V1

Esta rodada investiga três mecanismos antes de aumentar a complexidade do
algoritmo:

1. `intensidade × duração prevista`: o total esperado é a taxa prevista de
   kills por minuto multiplicada por uma distribuição de duração prevista;
2. ataque da equipe e exposição do adversário: cada equipe contribui com uma
   propensão ofensiva e cada adversário com uma propensão a conceder kills;
3. composição funcional: os dez campeões são descritos por funções de jogo,
   não apenas pelas tags gerais do Data Dragon.

O submodelo de duração compara Gamma e log-normal. O submodelo de intensidade
usa uma distribuição Negative Binomial com `log(duração)` como offset. A PMF
final integra a incerteza de duração, em vez de substituir a duração pela sua
média. A duração real do mapa previsto nunca entra como feature.

Os efeitos de equipe e adversário são estimados separadamente no modelo
hierárquico. Ambos usam pooling parcial por liga. Equipes novas ou com pouca
amostra permanecem próximas da média da liga.

Interações jogador–campeão foram retiradas da pesquisa operacional por decisão
de produto. Trocas de elenco e substituições não alteram o contrato do modelo.

## Arquétipos funcionais completos

Cada campeão deve ter valores entre zero e um para:

```text
engage
disengage
dive
pick
poke
siege
frontline
protect
scaling
early_pressure
skirmish
split_push
wave_clear
mobility
crowd_control
global_pressure
damage_physical
damage_magic
execution_difficulty
snowball_dependency
```

O classificador calcula os scores `engage`, `pick`, `poke_siege`, `dive`,
`protect`, `front_to_back`, `split_map`, `skirmish` e `scaling`. Ele também
mede cobertura funcional, redundância, equilíbrio de dano e dificuldade de
execução. O rótulo primário é o maior score; o secundário é o segundo maior.
A confiança depende da distância entre os dois primeiros scores e da cobertura
do catálogo. Os scores contínuos entram na ablação; os rótulos servem primeiro
para interpretação e avaliação segmentada.

## Modelo bayesiano congelável

O primeiro Bayes é uma Negative Binomial hierárquica com:

- distribuição preditiva de duração;
- intensidade por minuto;
- interceptos parcialmente agrupados por liga;
- efeitos parcialmente agrupados de ataque da equipe e exposição do adversário;
- coeficientes regularizados dos scores de composição;
- desvios jogador–campeão com shrinkage mais forte que os efeitos de jogador.

Todos os priors, features, transformações, número de chains, iterações, warmup,
seed e critérios de diagnóstico são congelados usando somente os folds de
2022–2025. O ano de 2026 pode ser relatado depois como comparação secundária,
mas não pode alterar nenhuma decisão. A confirmação limpa de promoção usa
somente mapas posteriores ao cutoff registrado no bundle congelado.

## Challengers de transformação e aprendizado de máquina

`qcut` só pode aprender seus pontos de corte dentro do treino de cada fold.
PCA também é ajustada apenas no treino e é challenger, porque pode esconder o
significado das variáveis. Boosting deve usar validação temporal, regularização
e produzir uma PMF calibrada. Nenhum desses métodos será escolhido por uma
métrica interna ou por desempenho em 2026; todos competem nos mesmos mapas
out-of-fold de 2022–2025.

Ridge, Lasso e Elastic Net escolhem a penalização em uma janela interna
formada pela parte mais recente do treino. Nenhum mapa do fold externo entra
na escolha de `lambda`. Os modelos recebem ratings de ataque e defesa contra
pares da liga e contra todas as ligas-alvo, momentum de 21 contra 120 dias,
perfis de agressividade por estado aos 15 minutos e sinais de snowball.

As referências locais e globais excluem a própria equipe. Snowball exige
vantagem mínima de duas kills aos 15 minutos e separa conversão em vitória de
velocidade de encerramento. Agressividade quando à frente ou atrás usa o sinal
do gold diff aos 15 minutos, não o resultado final.
