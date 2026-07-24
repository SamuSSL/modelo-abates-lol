# Especificação do produto

## Estado

Versão: 0.1.0  
Status: aguardando aprovação  
Produto: modelo probabilístico pós-draft de total de kills por mapa

## Revisão de escopo da V1 pública

Esta revisão substitui as restrições históricas de interface e deploy público
registradas abaixo.

- A V1 inclui interface Streamlit pública e compartilhável.
- O treinamento e a seleção estatística continuam canônicos em R.
- O modelo promovido será exportado em bundle portátil e executado em Python no
  Streamlit, com fixtures obrigatórias de paridade contra R.
- A API `plumber` permanece como referência local e caminho de diagnóstico, mas
  não será dependência do deploy público.
- Predições públicas serão persistidas em PostgreSQL externo configurado por
  secret. Banco ou arquivo no disco do contêiner não será considerado durável.
- O app não recomenda automaticamente apostas. Ele mostra probabilidades, odds
  justas, EV e bloqueios objetivos.
- O app poderá ser tornado público pelo controle de compartilhamento do
  Streamlit Community Cloud.

Referências operacionais:

- [Deploy no Streamlit Community Cloud](https://docs.streamlit.io/deploy/streamlit-community-cloud/deploy-your-app/deploy)
- [Dependências do app](https://docs.streamlit.io/deploy/streamlit-community-cloud/deploy-your-app/app-dependencies)
- [Compartilhamento público](https://docs.streamlit.io/deploy/streamlit-community-cloud/share-your-app)

## Problema

Depois que os dez campeões e jogadores de um mapa profissional são conhecidos, o usuário precisa estimar a distribuição do total de kills e comparar as probabilidades do modelo com uma linha e odds decimais de mercado.

O produto deve precificar incerteza. Uma estimativa pontual isolada não atende ao problema.

## Usuário e ambiente

O usuário inicial é uma única pessoa executando o projeto localmente no Windows, pelo RStudio, scripts R ou uma API `plumber`. Não há requisito inicial de autenticação, multiusuário, alta disponibilidade ou deploy público.

## Momento da previsão

A previsão ocorre depois do draft e antes do início do mapa. Para evitar qualquer dúvida operacional, o estado histórico de todos os mapas de uma série será o estado imediatamente anterior ao primeiro mapa da série.

## Requisitos funcionais

### PRD-001 — Criar previsão por mapa

O sistema deve aceitar exatamente duas equipes, sides opostos, cinco jogadores, cinco posições e cinco campeões por equipe.

### PRD-002 — Aceitar apenas linha `.5`

O sistema deve aceitar linhas não negativas com componente fracionário igual a `0.5`. Qualquer outro formato deve produzir erro de validação e não ser persistido como previsão válida.

### PRD-003 — Produzir distribuição

Uma previsão liberada deve retornar:

- PMF normalizada para valores inteiros de total de kills;
- média e mediana;
- intervalo preditivo central de 90%;
- probabilidades de Over e Under;
- `probability_push = 0`;
- odds justas decimais.

### PRD-004 — Calcular mercado

Quando uma odd decimal maior que 1 for fornecida:

```text
EV = P(win) * (decimal_odds - 1) - P(loss)
```

Quando ambas as odds forem fornecidas, o sistema deve calcular também:

```text
raw_implied_over = 1 / over_odds
raw_implied_under = 1 / under_odds
overround = raw_implied_over + raw_implied_under
no_vig_over = raw_implied_over / overround
no_vig_under = raw_implied_under / overround
```

### PRD-005 — Bloquear pouca amostra

Se equipe, jogador ou campeão não alcançar o mínimo aprovado, a resposta deve ter `status = "blocked"`, não deve expor EV acionável e deve listar as entidades com a mensagem `Pouca amostra para X. Não apostar`.

### PRD-006 — Alertar outras incertezas

Problemas não bloqueadores de cobertura, extrapolação, drift ou largura da distribuição devem reduzir a confiança e aparecer em `warnings`, mantendo a previsão.

### PRD-007 — Explicar composições

A resposta deve informar, para cada equipe, arquétipo primário, secundário, scores, confiança e versão da taxonomia.

### PRD-008 — Persistir consulta

Toda chamada válida ao serviço de previsão, inclusive uma resposta bloqueada, deve gerar um snapshot append-only contendo inputs, outputs, horário, versão do modelo e cutoff.

### PRD-009 — Registrar aposta opcional

Se `bet_side` for `over` ou `under`, o snapshot deve ser marcado como aposta realizada com stake fixa de 1 unidade. Sem `bet_side`, o snapshot é apenas uma consulta.

### PRD-010 — Reconciliar resultado

Quando um resultado novo for ingerido, o sistema deve tentar vinculá-lo ao evento previsto e calcular métricas prospectivas. ROI só pode usar apostas confirmadas.

### PRD-011 — Manter execução reproduzível

O mesmo modelo, input e seed devem produzir a mesma distribuição dentro da tolerância numérica documentada.

### PRD-012 — Disponibilizar metadados

O sistema deve expor ligas, equipes, jogadores, campeões, posições, versões e cutoffs válidos para que clientes não dependam de texto livre.

## Inputs públicos

```text
league
match_datetime
map_number
team_a
team_b
side_a
side_b
lineup_a[5]: player, position, champion
lineup_b[5]: player, position, champion
line
market_odds_over?
market_odds_under?
bet_side?
model_version?
```

IDs canônicos serão preferidos. Nomes poderão ser aceitos apenas quando a resolução for única.

## Outputs públicos

```text
status
event_id
expected_total_kills
median_total_kills
prediction_interval
pmf
line
probability_over
probability_under
probability_push
fair_odds_over
fair_odds_under
market
ev_over
ev_under
composition_a
composition_b
confidence
coverage
model_version
taxonomy_version
data_cutoff
warnings
blocked_reasons
snapshot_id
```

Campos probabilísticos e de EV poderão ser `null` quando `status = "blocked"`.

## Validações de entrada

- Liga deve ser uma das sete ligas canônicas.
- `match_datetime` deve usar ISO 8601 e ser posterior ao cutoff do modelo em produção.
- `map_number` deve ser inteiro positivo.
- Equipes devem ser diferentes e sides devem ser `Blue` e `Red`.
- Cada lineup deve conter exatamente uma posição canônica: `top`, `jng`, `mid`, `bot`, `sup`.
- Não pode haver jogador ou campeão duplicado no mapa.
- Jogador, equipe e campeão devem ser resolvidos no catálogo versionado.
- Linha deve ser finita, não negativa e terminar em `.5`.
- Odds, quando informadas, devem ser finitas e maiores que 1.
- `bet_side` deve ser ausente, `over` ou `under`; a odd do lado apostado deve existir.

## Comportamento probabilístico

Para linha `L = n + 0.5`:

```text
P(Over) = P(TotalKills >= n + 1)
P(Under) = P(TotalKills <= n)
P(Push) = 0
```

As probabilidades de Over e Under devem somar 1 dentro da tolerância numérica. A PMF deve somar 1 e cobrir cauda suficiente para que a massa truncada fique abaixo do limite documentado no artefato do modelo.

## Fora de escopo

- previsão do total de uma série;
- linhas inteiras ou asiáticas;
- recomendação automática de aposta;
- sizing de stake;
- identificação de bookmaker;
- interface visual Streamlit;
- atualização automática pela internet;
- autenticação e deploy público;
- previsões live durante o mapa;
- uso de odds como feature do modelo;
- deep learning;
- LLM durante a inferência.

## Critérios de aceite do produto

- Todos os requisitos PRD possuem testes ou evidências mapeadas.
- Nenhuma previsão utiliza dados indisponíveis no cutoff.
- Cálculos de PMF, Over, Under, fair odds e EV passam nos casos analíticos.
- O serviço bloqueia entidades insuficientes.
- O serviço responde em até 30 segundos no computador-alvo após o modelo estar carregado.
- Snapshots são persistidos sem sobrescrever registros anteriores.
- O modelo só recebe status de produção após os gates definidos em `evaluation-spec.md`.
