# Briefing do Projeto

Data de referência deste briefing: 28 de julho de 2026.

Este documento descreve o estado observado no repositório local
`C:\Users\Samuel\Documents\Modelo Abates LoL`. Ele separa o modelo que está no
Streamlit, os modelos que foram apenas pesquisados e os resultados que ainda
precisam de confirmação prospectiva.

## contexto do projeto

O projeto estima a distribuição de kills totais de um mapa profissional de
League of Legends depois que o draft está completo e antes do início da série.
O uso pretendido é auxiliar decisões em mercados de Over/Under de kills. O
produto não tenta adivinhar somente um número final: ele produz uma distribuição
de probabilidades para todos os totais plausíveis.

O fenômeno de interesse é definido como:

```text
total de kills do mapa = kills da equipe azul + kills da equipe vermelha
```

Cada mapa aparece uma vez no target. Deaths não são somadas, pois isso
duplicaria aproximadamente o mesmo evento. O produto aceita somente linhas
terminadas em `.5`, portanto não existe push.

As ligas canônicas são:

| Liga | Regra histórica principal |
|---|---|
| LCK | Mantida como LCK |
| LPL | Mantida como LPL |
| LEC | Mantida como LEC |
| CBLOL | Inclui LTA South em 2025 |
| LCS | Inclui LTA North em 2025 |
| LFL | Mantida como LFL |
| LES | Unifica historicamente LES e LVP SL |

Torneios internacionais podem contribuir como histórico auxiliar, mas não são
ligas-alvo de inferência.

O usuário informa:

- liga, data e horário planejados;
- número do mapa;
- equipe azul e equipe vermelha;
- cinco campeões de cada lado, nas posições top, jungle, mid, bot e support;
- linha de kills;
- odds decimais de Over e/ou Under, se disponíveis.

Jogadores foram retirados do modelo operacional. As linhas de jogadores do
Oracle's Elixir continuam úteis para auditoria do target e reconstrução do
draft, mas nomes, estabilidade de elenco e interações jogador-campeão não
participam da previsão atual. Essa decisão reduz problemas causados por
substituições e trocas de elenco.

As features são congeladas antes do primeiro mapa da série. Um mapa posterior
não pode influenciar um mapa anterior e mapas anteriores da mesma série não
entram nas features daquela série. Patch, playoffs, bans e ordem do draft foram
mantidos fora das features. Podem ser usados para auditoria e diagnósticos.

O projeto foi organizado com documentação SDD antes do código e testes TDD
durante a implementação. A documentação principal está em:

- `docs/product-spec.md`;
- `docs/data-contract.md`;
- `docs/modeling-spec.md`;
- `docs/evaluation-spec.md`;
- `docs/architecture.md`;
- `docs/testing-strategy.md`;
- `docs/decision-log.md`.

## objetivo atual

O objetivo operacional é fornecer probabilidades calibradas de Over e Under
para linhas de kills. Acertar exatamente o total não é o objetivo principal.
Para apostas, importa que uma previsão de 65% ocorra perto de 65% das vezes em
situações comparáveis.

O objetivo de pesquisa é descobrir se há informação pré-jogo que o modelo
simples ainda não aproveita. As hipóteses já investigadas incluem:

- ritmo recente de kills;
- ataque de uma equipe contra a defesa da adversária;
- intensidade no começo e depois de 15 minutos;
- comportamento quando uma equipe está à frente ou atrás;
- snowball e capacidade de encerrar;
- duração prevista;
- composição e arquétipos do draft;
- efeitos de equipe e adversário;
- relações não lineares;
- expectativas separadas de kills por equipe;
- dependência entre as kills das duas equipes;
- Monte Carlo paramétrico e Monte Carlo Histórico.

O critério principal de qualidade é o CRPS da distribuição completa. Em termos
simples, o CRPS pune simultaneamente uma previsão central ruim e uma
distribuição mal posicionada ou mal espalhada. Para o mercado Over/Under,
Brier, Log Loss e calibração por faixa de linha também são obrigatórios.

O objetivo econômico ainda não pode ser confirmado. Não há uma base histórica
com linhas, ambas as odds, fonte, horário de captura e liquidação. Por isso, os
resultados atuais medem capacidade estatística, não lucro real.

## estado atual

### Estado operacional

O Streamlit carrega a V1. Ele não carrega o ensemble-sombra nem os challengers
mais recentes.

| Item | Estado observado |
|---|---|
| Versão operacional | `v1-e1d364758f88` |
| Candidato | `nb_pace_draft` |
| Distribuição | Binomial Negativa |
| Taxonomia | `2026-static-v1` |
| Cutoff dos dados | `2026-07-25 17:35:45 UTC` |
| Dispersão `theta` | `24,3953` |
| Bundle | `app_data/model_bundle.json` |
| SHA-256 do bundle | `C827684CF5AF5B4E533769F4CC61ABEF68CB5A77E49AE536B8C99C5A412891F0` |
| Equipes no bundle | 232 |
| Equipes ativas na interface | 80 |
| Campeões na taxonomia | 173 |
| Campeões com cobertura amostral | 172 |
| Uso de jogadores | Não |

As 80 equipes disponíveis na interface são as que têm liga canônica, nome
atual e pelo menos um jogo registrado em 2026. A distribuição observada no
bundle é:

| Liga | Equipes selecionáveis |
|---|---:|
| CBLOL | 8 |
| LCK | 10 |
| LCS | 8 |
| LEC | 11 |
| LES | 8 |
| LFL | 21 |
| LPL | 14 |

O endereço declarado no README é
`https://modelo-abates-lol-sry25k3zh76r7ffs2qo8m3.streamlit.app/`. A
disponibilidade atual desse endereço não foi confirmada durante a preparação
deste briefing.

### Lógica exata da V1

A V1 começa validando a entrada:

1. as duas equipes devem ser diferentes e conhecidas;
2. cada lado deve ter exatamente top, jungle, mid, bot e support;
3. os dez campeões devem ser únicos;
4. os campeões precisam existir na taxonomia e passar pelo limite amostral;
5. as equipes precisam passar pelo limite amostral;
6. a linha deve terminar em `.5`.

Os limites operacionais armazenados no bundle são um jogo efetivo para equipe e
um jogo efetivo para campeão. Esse limite é permissivo. O shrinkage reduz o peso
de amostras pequenas, mas o gate ainda merece revisão prospectiva.

Depois da validação, o modelo cria quatro sinais:

| Sinal | Significado |
|---|---|
| `pace` | Média do ritmo histórico recente das duas equipes, em kills combinadas por minuto, com decaimento e shrinkage |
| `draft_frontline` | Média da capacidade estimada de linha de frente das duas composições |
| `draft_burst` | Média do potencial estimado de dano explosivo das duas composições |
| `draft_frontline_imbalance` | Diferença absoluta de frontline entre os dois lados |

Na taxonomia, o score simples de frontline usa defesa e indicação de tanque ou
lutador. Burst usa principalmente indicação de assassino ou mago. A taxonomia
completa calcula outros atributos e arquétipos, mas eles não entram diretamente
na V1 publicada.

Cada sinal é padronizado:

```text
z = (valor observado - centro do treino) / escala do treino
```

Centros e escalas congelados:

| Feature | Centro | Escala |
|---|---:|---:|
| `pace` | 0,837986 | 0,078225 |
| `draft_frontline` | 0,478542 | 0,060064 |
| `draft_burst` | 0,499705 | 0,140102 |
| `draft_frontline_imbalance` | 0,090481 | 0,068831 |

A média prevista é calculada na escala log:

```text
log(media_kills) =
    intercepto
  + efeito_da_liga
  + 0,106299 * pace_padronizado
  + 0,015449 * frontline_padronizada
  + 0,007442 * burst_padronizado
  + 0,016345 * desequilibrio_de_frontline_padronizado
```

O intercepto é `3,279128`. CBLOL é a liga de referência. Os demais ajustes são:

| Liga | Coeficiente na escala log |
|---|---:|
| CBLOL | 0 |
| LCK | -0,060015 |
| LCS | -0,045543 |
| LEC | 0,075357 |
| LES | -0,040526 |
| LFL | 0,011712 |
| LPL | -0,017623 |

O modelo aplica a exponencial ao resultado para obter a média esperada de
kills. Os coeficientes não significam kills diretamente. Por exemplo, o
coeficiente de `pace` é uma alteração multiplicativa na média para cada
desvio-padrão do ritmo.

A média e o `theta` alimentam uma Binomial Negativa. Essa escolha permite que a
variância seja maior que a média, algo observado nos dados. A PMF é calculada
até a massa residual ser inferior a `1e-10` e depois é normalizada.

Da PMF saem:

- média e mediana;
- intervalo preditivo de 90%;
- probabilidade de cada total de kills;
- probabilidade de Over;
- probabilidade de Under;
- odds justas;
- EV para odds informadas;
- probabilidade de push igual a zero.

Para uma linha `24,5`:

```text
P(Under 24,5) = P(total <= 24)
P(Over 24,5)  = P(total >= 25)
```

Se as duas odds forem informadas, o sistema calcula as probabilidades implícitas
e remove o vigorish normalizando `1/odd_over` e `1/odd_under`. O EV bruto é:

```text
EV = probabilidade_do_modelo * odd_decimal - 1
```

O identificador da previsão é determinístico e depende de liga, horário
planejado, equipes e número do mapa.

### Interpretação correta da saída

Uma média de 30 kills não afirma que o mapa terminará perto de 30. Ela representa
o centro de uma distribuição larga. Resultados como 14 ou 17 kills podem
acontecer mesmo quando a média é maior. O que deve ser auditado é a frequência
com que resultados baixos ficam fora do intervalo e a calibração das
probabilidades em muitos mapas, não dois casos isolados.

Isso não elimina o problema observado. Um resultado de 14 quando o intervalo de
90% começa em 16 é uma falha naquele mapa. Se eventos assim ocorrerem em mais de
10% dos mapas comparáveis, a cauda inferior está subestimada. A cobertura
agregada atual fica perto de 90%, mas isso pode esconder falhas em ligas, linhas
ou regimes específicos.

### Persistência e decisões de aposta

Ao calcular uma previsão, o sistema salva um evento de previsão. Isso preserva
o que o modelo realmente disse antes do jogo e impede seleção retroativa apenas
dos palpites convenientes.

A decisão de aposta é salva separadamente depois:

- `over`, com odd correspondente e stake fixa de uma unidade;
- `under`, com odd correspondente e stake fixa de uma unidade;
- `no_bet`, sem stake e sem odd de execução.

Portanto, calcular não equivale a confirmar uma aposta. A previsão fica no
histórico; a aposta só existe após uma decisão separada.

O armazenamento tenta usar PostgreSQL/Supabase por `DATABASE_URL` ou por
`[database].url` nos secrets do Streamlit. Se isso não estiver configurado, usa
`.local/predictions.sqlite`. O schema do Supabase está em:

- `sql/001_supabase_prediction_events.sql`;
- `sql/002_supabase_bet_decisions.sql`.

Não existe `secrets.toml` local neste checkout e existe um SQLite local. Isso
não prova que o deploy não usa Supabase, pois os secrets podem estar somente no
Streamlit Cloud. A conexão remota e a quantidade de registros no Supabase não
foram verificadas neste briefing.

### Estado do repositório

O repositório está na branch `main`, com remoto
`https://github.com/SamuSSL/modelo-abates-lol.git`.

O último commit local observado é:

```text
9f58b25cf60dc2e3877b468c62d76e5c09f18ec1
feat: remove player dependencies from model
```

Há alterações locais ainda não commitadas e vários arquivos de pesquisa ainda
não rastreados. Eles incluem a rodada de features do mercado de kills, modelos
acoplados, modelo hierárquico, modelo conjunto por equipe, Monte Carlo,
relatórios, scripts numerados e testes.

Consequência: os experimentos mais recentes existem no workspace local, mas não
estão confirmados como enviados ao GitHub nem publicados no Streamlit. O
Streamlit continua usando o bundle V1 commitado.

## o que já foi feito

### Descoberta, especificação e contratos

Foram documentados:

- objetivo do produto e limites de uso;
- contrato de entrada e saída;
- regras de ligas e aliases históricos;
- definição do target;
- regras de cutoff e prevenção de leakage;
- persistência de previsões e decisões;
- critérios de promoção de modelos;
- estratégia de testes e rastreabilidade.

### Ingestão e auditoria dos dados

Os CSVs locais do Oracle's Elixir de 2022 a 2026 foram ingeridos por manifesto.
O pipeline preserva informações de origem, temporada e hashes. Dados brutos,
processados e modelos ficam fora do Git quando apropriado.

O dataset analítico mais recente contém 11.883 mapas:

| Temporada | Mapas |
|---|---:|
| 2022 | 2.537 |
| 2023 | 2.525 |
| 2024 | 2.427 |
| 2025 | 2.684 |
| 2026 | 1.710 |

Resumo do target no conjunto atual:

| Estatística | Total de kills |
|---|---:|
| Média | 27,17 |
| Desvio-padrão | 8,41 |
| Mínimo | 3 |
| Máximo | 66 |

A duração média observada ficou perto de 32,5 minutos. A correlação entre a
duração observada do próprio mapa e kills totais foi aproximadamente `0,38`.
Essa relação existe, mas a duração real não está disponível antes da partida.

O conjunto pré-2026 tinha 10.173 mapas, média de 26,86, mediana de 26 e
desvio-padrão de 8,39. A razão variância/média por liga ficou aproximadamente
entre 2,35 e 2,74. Isso rejeita uma Poisson simples como descrição suficiente e
justifica a Binomial Negativa.

Também foi observado drift na média anual:

| Ano | Média de kills |
|---|---:|
| 2022 | 25,75 |
| 2023 | 25,73 |
| 2024 | 26,75 |
| 2025 | 29,09 |

### Recência, shrinkage e séries temporais

Foram comparadas janelas e decaimentos. A implementação atual usa históricos
recentes com decaimento exponencial e shrinkage para a média da liga. Uma
meia-vida de 60 dias significa que um mapa de 60 dias atrás recebe metade do
peso de um mapa de hoje; um mapa de 120 dias atrás recebe aproximadamente um
quarto.

O shrinkage impede que duas ou três partidas extremas transformem uma equipe em
um caso extremo. Quanto menor a amostra efetiva, mais o rating fica perto da
média da liga.

Além do modelo, foi criado tracking temporal de liga e equipe com índices
normalizados em 100:

- kills e deaths por minuto;
- ritmo combinado;
- ataque e defesa, globais e relativos à liga;
- agressividade quando à frente e quando atrás;
- snowball;
- duração;
- momentum;
- tendência;
- volatilidade;
- regimes como `hot_accelerating`, `hot_cooling`, `cold_recovering`,
  `cold_deteriorating`, `balanced` e `insufficient`.

Esses indicadores são úteis para diagnóstico e estudo de drift. Nem todos
entram na V1.

### Taxonomia e arquétipos de draft

A taxonomia determinística cobre 173 campeões e vinte atributos funcionais.
Ela não usa LLM durante a inferência.

Os atributos permitem calcular arquétipos como:

- engage;
- pick;
- poke/siege;
- dive;
- protect;
- front-to-back;
- split-map;
- skirmish;
- scaling.

O algoritmo produz scores, arquétipo primário, secundário e confiança. A V1
publicada usa apenas os agregados simples de frontline, burst e desequilíbrio de
frontline.

A limitação atual é importante: a taxonomia foi construída de forma
reproduzível a partir de descrições e regras, mas ainda não equivale a uma
revisão especialista, campeão por campeão e versão por versão. Lane, janelas de
poder, dependência de snowball e reworks materiais são difíceis de capturar
apenas pelo texto do kit.

### Variáveis estudadas

Foram criadas features com meias-vidas de 30, 60 e 120 dias:

- kills e deaths por minuto;
- intensidade combinada do confronto;
- kills até 10 e 15 minutos;
- ritmo depois de 15 minutos;
- dano causado e recebido por minuto;
- assistências por minuto;
- atividade de torres, dragões, arautos e barões;
- tamanho da vantagem aos 15 minutos;
- conversão de vantagem em vitória;
- tempo para encerrar quando à frente;
- capacidade de prolongar quando atrás;
- níveis, tendências, razões e desequilíbrios entre janelas;
- ratings de ataque e defesa;
- agressividade, snowball e momentum;
- atributos e arquétipos do draft.

As maiores correlações pré-jogo ajustadas por liga e temporada foram:

| Sinal | Correlação com kills totais |
|---|---:|
| Ataque contra defesa adversária na liga | 0,156 |
| Intensidade histórica longa | 0,148 |
| Intensidade histórica média | 0,146 |
| Intensidade histórica curta | 0,135 |
| Ritmo pós-15 longo | 0,129 |
| Ritmo pós-15 médio | 0,126 |
| Agressividade quando à frente | 0,115 |
| Pressão global de ataque contra defesa | 0,114 |
| Agressividade quando atrás | 0,110 |
| Dano histórico por minuto | 0,100 |
| Atividade de assistências | 0,098 |
| Ritmo inicial | 0,097 |
| Frontline do draft | 0,084 |

Esses sinais são reais, mas individualmente fracos. Eles também são
correlacionados entre si. Adicionar todos sem regularização aumenta o risco de
o modelo memorizar ruído.

### Validação temporal

O desenvolvimento principal usa nove folds rolling-origin, nos primeiros três
trimestres de 2023, 2024 e 2025. Em cada fold, o treino contém somente o passado
disponível. Foram geradas 7.586 previsões fora da amostra.

O ano de 2022 serve como histórico inicial. 2026 foi usado como comparação
secundária depois do desenvolvimento, mas já foi consultado em várias rodadas.
Ele não é mais um holdout totalmente limpo. A confirmação limpa precisa usar
mapas posteriores ao cutoff congelado.

### Modelos simples

Foram implementados e comparados:

- médias globais, por liga e móveis;
- Poisson;
- Binomial Negativa;
- V1 com ritmo e draft;
- Ridge regularizado;
- PCA seguida de Binomial Negativa;
- ensembles de PMFs.

A Poisson foi rejeitada porque suas distribuições ficaram estreitas demais. A
Binomial Negativa descreveu melhor a sobredispersão.

### Duração e intensidade

Foi testada explicitamente a identidade:

```text
total de kills = duração do mapa × kills por minuto
```

A duração observada tem correlação `0,38` com o total, mas a duração prevista
foi pouco informativa:

- correlação da previsão de duração com a duração real melhorou de cerca de
  `0,085` para `0,118`;
- um XGBoost de duração chegou a `0,128` em 2026;
- a cobertura de 90% da duração ficou perto de `89%`.

Também foi estimada dependência negativa entre duração e intensidade, com
coeficiente médio de aproximadamente `-0,160`. Mapas mais longos tendem a ter
menos kills por minuto. Isso significa que duração e intensidade não devem ser
simuladas como independentes.

O modelo acoplado respeitou essa relação e melhorou o CRPS no desenvolvimento,
mas não confirmou melhora em 2026. A duração enriquecida permaneceu como
diagnóstico, não como dependência da V1.

### Modelo Bayesiano

Foi implementado um modelo hierárquico Bayesiano com MCMC nos folds de
2023–2025. Ele incluiu duração, intensidade, ataque da equipe, exposição do
adversário, draft e duas contagens de kills.

O MCMC funcionou numericamente:

- zero divergências;
- zero violações de tree depth;
- R-hat máximo abaixo de 1,01.

O problema não foi falta de iterações. A distribuição ficou larga demais:

| Modelo | CRPS | Log Score | Cobertura 90% |
|---|---:|---:|---:|
| V1 reconstruída | 4,5622 | 3,4924 | 91,73% |
| Bayes hierárquico | 4,7515 | 3,5950 | 97,94% |

Uma cobertura de quase 98% para um intervalo nominal de 90% mostra excesso de
incerteza. Rodar mais iterações estimaria com mais precisão o mesmo modelo
largo; não resolveria a especificação.

### Modelo hierárquico não linear

Também foi testado um GAM Negative Binomial com:

- curvas cúbicas regularizadas;
- interações;
- interceptos por liga;
- efeitos encolhidos de equipe azul e vermelha;
- dispersão específica por mapa.

Resultado:

| Período | Modelo | CRPS | Log Score | Cobertura 90% |
|---|---|---:|---:|---:|
| 2023–2025 | V1 | 4,5622 | 3,4924 | 91,73% |
| 2023–2025 | GAM hierárquico global | 4,5594 | 3,4937 | 91,46% |
| 2026 | V1 | 4,4959 | 3,4836 | 90,41% |
| 2026 | GAM hierárquico global | 4,5469 | 3,5076 | 87,49% |

O pequeno ganho de CRPS no desenvolvimento não foi estatisticamente estável e
o Log Score piorou. Em 2026 houve piora material. Os dados encolheram quase
todas as curvas e efeitos de equipe para relações próximas de lineares ou zero.
O modelo não foi promovido.

### Decomposição por equipe e Monte Carlo

Foi implementada a ideia de estimar kills da equipe azul e da equipe vermelha
separadamente e depois recompor o total.

Foram testados:

- intensidade por minuto de cada equipe;
- efeitos Ridge de equipe e adversário;
- duração lognormal;
- Binomial Negativa por equipe;
- soma independente exata por convolução;
- duração compartilhada;
- total coerente com divisão Beta-Binomial;
- dependência residual por cópula Gaussiana;
- Monte Carlo Histórico puro;
- Monte Carlo Histórico condicional;
- choques históricos pareados de duração e kills;
- misturas paramétricas e históricas.

O Monte Carlo Histórico sorteou vetores reais passados, preservando juntos
duração, kills azuis e kills vermelhas. O método condicional procurou partidas
historicamente semelhantes. O método de choques reaplicou percentis históricos
às expectativas atuais.

Resultado em 2023–2025:

| Modelo | CRPS | Log Score | Cobertura 90% |
|---|---:|---:|---:|
| V1 | 4,5622 | 3,4924 | 91,73% |
| Total coerente | 4,5712 | 3,5036 | 93,99% |
| Cópula Gaussiana | 4,5754 | 3,5040 | 94,07% |
| Soma independente exata | 4,5788 | 3,5072 | 94,61% |
| Histórico condicional | 4,6789 | 5,1132 | 89,92% |
| Histórico puro | 4,6818 | 4,5250 | 90,65% |
| Choques históricos | 4,8550 | 5,0238 | 96,03% |

Resultado secundário em 2026:

| Modelo | CRPS | Log Score | Cobertura 90% |
|---|---:|---:|---:|
| V1 | 4,4959 | 3,4836 | 90,41% |
| Total coerente | 4,5025 | 3,4936 | 93,98% |
| Histórico condicional | 4,6453 | 4,1921 | 90,06% |
| Histórico puro | 4,6619 | 3,9014 | 90,53% |
| Choques históricos | 4,8255 | 6,8668 | 93,80% |

O Monte Carlo Histórico preservou caudas reais, mas perdeu informação
condicional suficiente para piorar principalmente o Log Score.

A dependência entre equipes também foi estudada. A correlação residual das
kills ficou entre `-0,42` e `-0,37`. Depois de shrinkage, a cópula usou valores
entre `-0,31` e `-0,28`. As médias previstas das duas equipes tiveram correlação
`-0,087`, enquanto as kills observadas tiveram `-0,259`. Existe dependência não
capturada, mas modelá-la explicitamente não melhorou a distribuição do total.

Na comparação com 100 mil sorteios, nenhum orçamento até 40 mil cumpriu
simultaneamente as tolerâncias pré-definidas:

| Sorteios | Erro máximo de Over/Under | Diferença média de CRPS |
|---:|---:|---:|
| 1.000 | 4,99 p.p. | 0,1233 |
| 5.000 | 2,56 p.p. | 0,0529 |
| 10.000 | 1,62 p.p. | 0,0376 |
| 40.000 | 1,11 p.p. | 0,0223 |

Quando existe uma solução matemática exata, como a convolução das PMFs, ela é
preferível à simulação por ser determinística e não introduzir ruído de Monte
Carlo.

### Machine learning e redução de dimensionalidade

PCA, QCut e XGBoost foram avaliados.

- PCA melhorou o CRPS em aproximadamente `0,005`, cerca de `0,11%`, mas o
  intervalo de incerteza incluiu ganho e piora.
- XGBoost com as features enriquecidas obteve CRPS `4,5775` no desenvolvimento
  contra `4,5622` da V1.
- QCut também piorou.

Deep learning não foi implementado. O tamanho do conjunto, a baixa força
individual dos sinais e a necessidade de validação temporal tornam alto o
risco de uma rede aprender ruído. Os resultados do GAM e XGBoost não sustentam
a hipótese de que mais flexibilidade, por si só, resolverá o problema.

### Ensemble e modelo-sombra

O melhor resultado médio no desenvolvimento foi o ensemble 50% V1 e 50% modelo
acoplado:

| Modelo | CRPS | Log Score | MAE | RMSE | Cobertura 90% |
|---|---:|---:|---:|---:|---:|
| V1 | 4,5622 | 3,4924 | 6,459 | 8,198 | 91,7% |
| V1 + acoplado | 4,5316 | 3,4866 | 6,407 | 8,139 | 93,0% |
| V1 + Ridge | 4,5401 | 3,4884 | 6,421 | 8,155 | 92,6% |

O modelo congelado como sombra foi o ensemble 50% V1 e 50% Ridge, por sua
estabilidade e simplicidade:

```text
kill-market-shadow-c2e3e7efd938
```

Métricas do modelo-sombra:

| Período | CRPS | Log Score | Cobertura 90% |
|---|---:|---:|---:|
| 2023–2025 | 4,5401 | 3,4884 | 92,62% |
| 2026, comparação secundária | 4,4836 | 3,4804 | 91,99% |

Na média de 14 linhas entre 18,5 e 44,5:

| Período | Modelo | Brier | Log Loss |
|---|---|---:|---:|
| 2023–2025 | V1 | 0,14764 | 0,45464 |
| 2023–2025 | V1 + Ridge | 0,14684 | 0,45223 |
| 2026 | V1 | 0,14964 | 0,46199 |
| 2026 | V1 + Ridge | 0,14920 | 0,46043 |

O ganho é pequeno. No desenvolvimento, o bootstrap foi favorável. Em 2026, o
intervalo incluiu empate ou piora. Por isso, o modelo-sombra ainda não substitui
a V1.

### Interface, API e tracking

O projeto possui:

- função canônica de inferência em R;
- bundle portátil e inferência correspondente em Python;
- API `plumber` com `/health`, `/v1/metadata` e `/v1/predict`;
- Streamlit com previsão e tracking temporal;
- cliente de contrato em Python;
- persistência append-only;
- reconciliação entre previsões e resultados;
- cálculo prospectivo de calibração e ROI apenas para apostas confirmadas.

### Testes e verificações

Os testes cobrem:

- schema e granularidade;
- target sem duplicar deaths;
- remakes e partidas inválidas;
- IDs, aliases e séries;
- cutoffs e ausência de futuro;
- rolling features;
- PMF, odds, EV e vigorish;
- drafts e campeões duplicados;
- taxonomia e amostra insuficiente;
- serialização, API e persistência;
- paridade R–Python;
- modelos acoplados, hierárquicos e Monte Carlo.

Na preparação deste briefing:

- os testes Python passaram: 19 testes;
- a execução recente da suíte R havia passado sem falhas de teste;
- o `R CMD check` mais recente instalou, carregou e testou o pacote, mas manteve
  avisos estruturais de arquivos Stan/binários, diretórios de check, caminhos
  longos e organização da pasta `data`.

Esses avisos não demonstram erro estatístico, mas impedem dizer que o pacote
está completamente limpo para distribuição.

## plano em andamento

O plano efetivamente em andamento é manter a V1 pública e acompanhar o
ensemble-sombra sem alterar as probabilidades mostradas ao usuário.

O fluxo esperado é:

1. registrar toda previsão feita antes do mapa;
2. registrar separadamente se houve aposta, lado, odd e stake;
3. reconciliar o evento com o resultado depois que um CSV novo chegar;
4. comparar V1 e sombra no mesmo conjunto prospectivo;
5. medir CRPS, Log Score, Brier, calibração e resultado por linha e liga;
6. comparar as probabilidades com o mercado sem vig;
7. promover somente se o ganho persistir fora da amostra e não esconder
   deterioração em alguma liga.

Somente mapas posteriores a `2026-07-25 17:35:44 UTC` podem contribuir para a
confirmação prospectiva limpa do modelo-sombra atual.

O status correto é:

```text
GO WITH CONDITIONS para pesquisa e acompanhamento em sombra.
HOLD para afirmar que existe vantagem econômica de aposta.
```

## gargalos e riscos

### Falta de odds históricas

Sem odds históricas capturadas antes dos jogos, não é possível medir:

- ROI confiável;
- closing line value;
- vantagem contra a probabilidade sem vig;
- degradação entre horário da previsão e fechamento;
- resultado condicionado ao edge exigido.

Um CRPS melhor não garante que o modelo seja melhor que o mercado.

### Holdout de 2026 já consultado

2026 foi usado como comparação em várias rodadas. Continuar ajustando o modelo
olhando esse resultado transforma o período em desenvolvimento informal. A
próxima evidência limpa precisa vir de mapas futuros.

### Ganhos pequenos

O melhor ensemble melhorou o CRPS de desenvolvimento em cerca de `0,67%`. O
ensemble-sombra melhorou aproximadamente `0,48%`. São ganhos plausíveis, mas
pequenos. Custos de manutenção, drift e erro operacional podem anulá-los.

### Calibração agregada pode esconder falhas

Cobertura de 90% perto de 90% no total não garante boa cobertura:

- em cada liga;
- em linhas baixas ou altas;
- em favoritos fortes;
- em drafts extremos;
- em mudanças de meta;
- em equipes com pouca amostra.

Os erros recentes de 14 e 17 kills são compatíveis com eventos de cauda
isolados. Eles se tornam evidência contra o modelo se forem frequentes no
segmento relevante.

### Sinais pré-jogo fracos

A maior correlação ajustada encontrada foi `0,156`. O fenômeno tem grande
componente aleatório e latente. Draft, execução, vantagem inicial e decisões
dentro do mapa explicam kills, mas boa parte disso só se torna visível depois
que o mapa começa.

### Previsão de duração fraca

Duração real importa, mas a duração pré-jogo é difícil de prever. A correlação
de aproximadamente `0,118` significa que a maior parte da variação permanece
desconhecida antes da partida. Propagar uma previsão ruim de duração pode
alargar ou deslocar a distribuição final.

### Taxonomia incompleta como conhecimento especialista

Os 173 campeões têm cobertura mecânica, mas ainda faltam revisão manual,
versionamento detalhado de reworks e validação dos atributos contra resultados
temporais. O draft pode estar subaproveitado por qualidade da representação,
não necessariamente por irrelevância do draft.

### Gates amostrais permissivos

Um jogo efetivo é pouco para bloquear ou liberar uma entidade. O shrinkage
protege parcialmente, mas não substitui uma regra de cobertura calibrada por
risco de erro e disponibilidade operacional.

### Modelo operacional não é o melhor backtest médio

A V1 é o modelo publicado por simplicidade e estabilidade. Ela não tem o menor
CRPS médio entre todos os experimentos. O melhor backtest médio foi um
ensemble, mas a vantagem ainda não foi confirmada prospectivamente.

### Estado local não publicado

Há arquivos modificados e não rastreados. Isso cria risco de:

- perder resultados;
- não reproduzir exatamente um relatório;
- confundir código local com código publicado;
- gerar bundle a partir de um estado não versionado.

### Supabase não verificado

O código suporta Supabase, mas este briefing não confirmou o projeto remoto,
secrets, conectividade, políticas RLS nem contagem de eventos. Também não foi
possível confirmar pelo repositório o nome do projeto Supabase separado.

### Manifestos potencialmente defasados

O conjunto analítico atual registra 11.883 mapas, enquanto uma validação de
manifesto anterior mencionou 11.833 registros. Essa diferença precisa ser
reconciliada antes de declarar uma reprodução integral a partir do zero.

## melhorias recomendadas

### Tornar a coleta prospectiva o trabalho principal

Novos modelos não resolvem a maior incerteza atual. O passo com maior valor é
capturar previsões e mercado antes do mapa:

- timestamp;
- linha;
- odd Over;
- odd Under;
- fonte;
- decisão;
- resultado;
- versão do modelo;
- cutoff.

Isso permite saber se a probabilidade está calibrada e se supera a informação
contida nas odds.

### Avaliar por faixa de linha

O mercado não oferece sempre a mesma linha. A calibração deve ser separada em
faixas, por exemplo:

- linhas baixas;
- linhas centrais;
- linhas altas;
- caudas com pouca frequência.

O modelo pode estar bem calibrado no centro e otimista demais no Over de linhas
baixas.

### Monitorar caudas e cobertura condicional

Além da cobertura agregada, acompanhar:

- frequência abaixo do limite inferior de 90%;
- frequência acima do limite superior;
- cobertura por liga;
- cobertura por quartil da média prevista;
- cobertura por força relativa;
- cobertura por confiança do draft;
- largura média do intervalo.

### Revisar manualmente a taxonomia

Uma melhoria justificável é revisar campeões por função e versão, priorizando os
mais usados. A validação deve ser por ablação temporal: taxonomia automática
contra taxonomia revisada, mantendo o resto igual.

### Calibrar o gate de amostra

Testar limites maiores em dados históricos sem escolher o valor pelo resultado
de 2026. O objetivo é equilibrar:

- cobertura operacional;
- erro para equipes novas;
- estabilidade do ritmo;
- confiabilidade do draft.

### Organizar e congelar o estado local

Antes de outra rodada:

- separar arquivos de produção dos experimentos;
- registrar seeds e hashes;
- gerar artefatos a partir de commit limpo;
- reconciliar 11.833 contra 11.883 registros;
- executar a pipeline completa;
- repetir testes R, Python e check.

### Não priorizar agora

Com a evidência atual, não é prioridade:

- aumentar iterações do Bayes já rejeitado;
- publicar o GAM hierárquico;
- adicionar Monte Carlo Histórico ao Streamlit;
- substituir convolução exata por simulação;
- iniciar deep learning sem uma hipótese nova e mensurável;
- usar 2026 repetidamente para escolher novos hiperparâmetros.

## próximos passos

1. Confirmar que o Streamlit Cloud usa o commit e o bundle esperados.
2. Confirmar a conexão com o Supabase separado, RLS e inserção nas tabelas de
   previsões e decisões.
3. Verificar se as previsões já feitas desde o cutoff foram salvas antes dos
   mapas.
4. Reconciliar essas previsões com os CSVs novos.
5. Salvar linha, ambas as odds e horário de captura em toda oportunidade
   avaliada.
6. Gerar relatório prospectivo V1 contra ensemble-sombra.
7. Reportar CRPS e Log Score da distribuição completa.
8. Reportar Brier, Log Loss e calibração por linha.
9. Comparar o modelo com a probabilidade implícita sem vig.
10. Exigir amostra prospectiva suficiente antes de qualquer promoção.
11. Só depois decidir entre promover o ensemble, recalibrá-lo ou manter a V1.
12. Versionar e publicar os experimentos locais somente após reprodução limpa.

Uma regra de promoção ainda precisa ser fechada com números prospectivos. Ela
deve exigir, no mínimo:

- melhora de CRPS e Log Score;
- Brier não pior;
- calibração aceitável por linha;
- ausência de degradação material por liga;
- estabilidade em blocos temporais;
- comparação favorável contra o mercado sem vig;
- nenhuma dependência de resultados vistos depois do cutoff.

## indicadores importantes

### CRPS

Métrica principal do projeto. Avalia a distribuição inteira. Quanto menor,
melhor. Penaliza probabilidades mal distribuídas mesmo quando a média parece
razoável.

Referência atual:

| Período | V1 | Ensemble-sombra |
|---|---:|---:|
| 2023–2025 | 4,5622 | 4,5401 |
| 2026 secundário | 4,4959 | 4,4836 |

### Log Score

Pune fortemente quando o modelo atribui probabilidade muito pequena ao que
realmente aconteceu. Quanto menor, melhor. É sensível a caudas mal modeladas.

| Período | V1 | Ensemble-sombra |
|---|---:|---:|
| 2023–2025 | 3,4924 | 3,4884 |
| 2026 secundário | 3,4836 | 3,4804 |

### Brier

Avalia uma pergunta binária, como Over 24,5. É a média do erro quadrático entre
a probabilidade e o resultado zero ou um. Quanto menor, melhor.

Na média das linhas de 18,5 a 44,5:

| Período | V1 | Ensemble-sombra |
|---|---:|---:|
| 2023–2025 | 0,14764 | 0,14684 |
| 2026 secundário | 0,14964 | 0,14920 |

### Log Loss por linha

É semelhante ao Brier, mas pune mais previsões confiantes e erradas. Quanto
menor, melhor.

| Período | V1 | Ensemble-sombra |
|---|---:|---:|
| 2023–2025 | 0,45464 | 0,45223 |
| 2026 secundário | 0,46199 | 0,46043 |

### Calibração

É a correspondência entre probabilidade prevista e frequência observada. Um
grupo de previsões de Over com 70% deve acertar aproximadamente 70% ao longo do
tempo.

Esse é o indicador mais importante para transformar a distribuição em decisão
de Over/Under, junto com a comparação contra a probabilidade sem vig do mercado.

### Cobertura do intervalo de 90%

Um intervalo de 90% deveria conter o resultado em aproximadamente 90 de cada
100 mapas. Cobertura maior demais costuma indicar intervalo largo; menor demais,
intervalo estreito.

| Período | V1 | Ensemble-sombra |
|---|---:|---:|
| 2023–2025 | 91,73% | 92,62% |
| 2026 secundário | 90,41% | 91,99% |

### MAE e RMSE

MAE mede a distância absoluta média entre média prevista e total real. RMSE
pune mais os erros grandes. São úteis, mas não avaliam toda a distribuição e
não devem selecionar sozinhos um modelo de Over/Under.

V1:

| Período | MAE | RMSE |
|---|---:|---:|
| 2023–2025 | 6,459 | 8,198 |
| 2026 secundário | 6,417 | 8,074 |

### Comparação sem vig

Quando há as duas odds, o mercado fornece uma probabilidade implícita depois da
remoção da margem. Essa é a referência econômica real. O modelo só tem valor
para aposta se sua probabilidade agregar informação além dessa referência.

### ROI e CLV

São importantes, mas ainda indisponíveis de forma confiável. ROI exige apostas
registradas sem seleção retrospectiva. CLV exige a odd tomada e a odd de
fechamento comparáveis.

## perguntas para o conselho de IAs

1. Dado que o ensemble-sombra melhora o CRPS em menos de 1%, qual tamanho de
   amostra prospectiva é necessário para uma decisão de promoção com poder
   razoável?
2. Como definir uma regra de promoção conjunta para CRPS, Log Score, Brier e
   calibração sem criar tuning indireto no período prospectivo?
3. Qual método de calibração por linha preserva monotonicidade entre linhas e
   evita overfitting com poucas observações?
4. Como comparar de forma justa o modelo com odds sem vig quando linhas e odds
   mudam entre a previsão e o fechamento?
5. Vale desenvolver uma taxonomia especialista versionada antes de concluir que
   draft agrega pouco?
6. O gate de um jogo efetivo é permissivo demais? Qual critério relaciona melhor
   cobertura operacional e risco preditivo?
7. Como medir separadamente erro de cauda inferior, que gerou os casos recentes
   de 14 e 17 kills?
8. Há uma especificação mais simples de fator latente conjunto que capture a
   correlação negativa entre kills das equipes sem alargar a distribuição?
9. A melhora do modelo acoplado em 2023–2025 é sinal repetível ou consequência
   da mesma informação de ritmo reaparecendo em várias features?
10. Quais variáveis pré-jogo adicionais podem ser obtidas de forma auditável sem
    introduzir patch, dados em tempo real ou leakage?
11. Como identificar drift suficiente para retreinar sem reagir a ruído de
    poucas semanas?
12. Qual benchmark de mercado deve substituir a V1 como referência principal
    assim que houver odds prospectivas suficientes?

## pontos onde o agente está inferindo ou não tem certeza

- O código e o bundle confirmam que a V1 é o modelo operacional local. Não foi
  possível confirmar que o Streamlit público está online ou servindo exatamente
  esse commit neste momento.
- O código suporta Supabase, mas a conexão remota, o projeto separado, os
  secrets e a persistência efetiva não foram verificados.
- O modelo-sombra está congelado em configuração local. Não há evidência neste
  briefing de que ele esteja sendo executado automaticamente em cada previsão
  pública.
- O relatório mais antigo do holdout tinha 1.512 mapas elegíveis e métricas
  ligeiramente diferentes. Ele antecede a atualização dos dados e a remoção dos
  jogadores. As comparações padronizadas de 7.586 mapas e 1.710 mapas são as
  referências mais recentes usadas aqui.
- O manifesto anterior com 11.833 registros e o dataset atual com 11.883 mapas
  não foram reconciliados.
- Os testes confirmam consistência de código nos cenários cobertos. Eles não
  confirmam que as probabilidades vencerão o mercado.
- As correlações das features são associações preditivas. Elas não provam que
  uma variável causa mais ou menos kills.
- O status `GO WITH CONDITIONS` vale para pesquisa e coleta em sombra. A
  capacidade de gerar uma previsão não deve ser interpretada como autorização
  estatística para apostar.
