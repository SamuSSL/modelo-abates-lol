# Registro de decisões

## 2026-07-24 — Rodada estrutural antes do Bayes

Decisão aprovada pelo usuário:

- decompor explicitamente intensidade e duração prevista;
- criar taxonomia funcional completa e arquétipos de composição;
- trazer efeitos separados de equipe e adversário;
- estudar interação jogador–campeão com shrinkage forte;
- desenvolver Bayes usando apenas folds de 2022–2025;
- usar 2026 somente como comparação secundária após congelamento;
- reservar a confirmação limpa para mapas posteriores ao cutoff atual;
- comparar Bayes, modelos diretos, decomposição e challengers de transformação
  ou machine learning nos mesmos mapas temporais.

Motivo: representar mecanismos mais estáveis do fenômeno e evitar que a escolha
do modelo seja guiada pelo ruído do total final ou pelo período de 2026 já
observado.

## 2026-07-24 — Seleção congelada após nove folds

Os nove folds de 2023–2025 usaram somente histórico iniciado em 2022. O V1
reconstruído permaneceu como referência com CRPS 4,5622.

PCA + Negative Binomial obteve CRPS 4,5571. A diferença de -0,0050 teve
intervalo bootstrap de -0,0219 a 0,0121. O ganho foi pequeno, incerto e não
uniforme por fold e liga. PCA permanece challenger de pesquisa e não é
promovida.

O Bayes hierárquico convergiu nos nove folds, com zero divergências e R-hat
máximo inferior a 1,01. Mesmo assim, obteve CRPS 4,7515 e cobertura de 90% de
97,94%, indicando excesso de dispersão. Mais iterações não corrigem esse erro
estrutural. Ele não é promovido.

QCut, XGBoost e as decomposições Gamma e log-normal também ficaram abaixo da
referência. Nenhum modelo novo foi promovido. O resultado de 2026 será
comparação secundária e não poderá alterar esta decisão.

O cutoff prospectivo congelado é 2026-07-22 20:02:30 UTC. Confirmação limpa
exige mapas com resultado posterior a esse cutoff.
## D-031 — Taxonomia estática de 2026

- Contexto: o usuário dispensou tratamento de reworks e quer uma taxonomia única baseada em 2026.
- Decisão: usar uma versão estática de 2026 em todos os mapas de 2022–2026.
- Leakage: resultados de partidas de 2026 não entram em features históricas; 2026 serve apenas para catálogo e definição estática enquanto holdout estiver fechado.
- Consequência: nenhum versionamento por rework ou data; campeão sem registro bloqueia.
- Data: 2026-07-23.
- Status: aprovado.

## D-032 — Deploy público no Streamlit

- Contexto: a V1 precisa ser compartilhável com outros usuários.
- Decisão: publicar interface no Streamlit Community Cloud.
- Arquitetura: R treina e exporta bundle; Python executa inferência congelada com testes de paridade.
- Persistência: PostgreSQL externo por secret; DuckDB permanece local.
- `plumber`: referência local e diagnóstico, não dependência do app público.
- Data: 2026-07-23.
- Status: aprovado.

## D-033 — Auditoria de jogadores e drafts

- Resultado: todos os 12.316 mapas-alvo após exclusão têm dez jogadores,
  dez campeões e cinco posições canônicas.
- Exceção: três linhas sem `playerid` permanecem auditáveis por nome,
  equipe, posição e campeão.
- Decisão: usar nome e posição como chave substituta na pesquisa e emitir
  alerta na inferência quando o ID oficial estiver ausente.
- Data: 2026-07-24.
- Status: implementado.

## D-034 — Taxonomia estática objetiva

- Versão: `2026-static-v1`, baseada no Data Dragon 16.14.1.
- Cobertura: 173 campeões no catálogo e todos os 170 observados.
- Conteúdo: somente papéis e notas oficiais.
- Decisão: não criar versões de rework nem usar resultados competitivos
  de 2026 para produzir atributos retroativos.
- Data: 2026-07-24.
- Status: implementado.

## D-035 — Draft promovido; jogadores rejeitados como sinal

- Evidência: `player_draft_model_*` e bootstrap pareado por semana.
- Resultado: `nb_pace_draft` obteve CRPS 4,5622 contra 4,5861 de
  `nb_pace`.
- Incerteza: diferença de -0,0240, com intervalo bootstrap de 95% entre
  -0,0403 e -0,0080.
- Consistência: ganho em oito de nove folds e seis de sete ligas.
- Jogadores: o bloco isolado piorou 0,0142; combinado ao draft piorou
  0,0133.
- Decisão: manter draft; rejeitar jogadores como variáveis preditivas
  na V1. Jogadores permanecem no contrato e na proteção de amostra.
- Holdout: 2026 permaneceu selado.
- Data: 2026-07-24.
- Status: selecionado em desenvolvimento.

## D-036 — Ensemble simples rejeitado

- Candidato: média 50/50 das PMFs de `nb_pace_draft` e `nb_pace`.
- Resultado: CRPS 4,5657 contra 4,5622 do draft isolado.
- Incerteza: diferença de 0,0036, com intervalo bootstrap de 95% entre
  -0,0043 e 0,0115.
- Decisão: rejeitar o ensemble porque acrescenta complexidade sem ganho
  comprovado.
- Holdout: 2026 permaneceu selado.
- Data: 2026-07-24.
- Status: rejeitado em desenvolvimento.

## D-037 — Limites de jogador e campeão

- Campeão: mínimo de 1 jogo efetivo; retém 97,51% da validação.
- Evidência do campeão: entre elegíveis, o ganho do draft teve intervalo
  de 95% entre -0,0400 e -0,0070; entre bloqueados, o intervalo cruzou
  zero.
- Jogador: nenhum corte separou estatisticamente o ganho do draft,
  porque estatísticas de jogador não entram no modelo promovido.
- Decisão: manter o piso operacional mínimo de 1 jogo efetivo para
  jogador, conforme requisito aprovado de bloquear entidades sem
  histórico. O limite é de segurança, não um sinal preditivo.
- Holdout: autorizado a abrir após este congelamento.
- Data: 2026-07-24.
- Status: selecionado em desenvolvimento.

## D-038 — Promoção no holdout final de 2026

- Amostra: 1.512 mapas operacionalmente elegíveis.
- Resultado: `nb_pace_draft` obteve CRPS 4,4296 contra 4,4565 de
  `nb_pace` e 4,5703 de `nb_league`.
- Calibração: cobertura de 90% em 90,67%; erro médio de +0,45 kill.
- Segmentos: ganho em seis ligas; LEC piorou 0,0513 contra ritmo,
  abaixo do limite pré-registrado de 0,10.
- Guardrails: todos passaram.
- Decisão: promover `nb_pace_draft` para a V1.
- Data: 2026-07-24.
- Status: promovido.

## Convenção

Cada decisão possui contexto, alternativas, decisão, consequência, data e status. Decisões empíricas futuras devem anexar o caminho do relatório ou artefato que as sustenta.

## D-001 — Dados locais

- Contexto: o usuário quer controlar quais snapshots do Oracle's Elixir entram no projeto.
- Alternativas: download automático, arquivo sempre atualizado, arquivos locais.
- Decisão: usar somente arquivos locais de 2022–2026, registrados por manifesto e hash.
- Consequência: atualização será manual e reproduzível; ausência de temporada bloqueia experimentos que dependem dela.
- Data: 2026-07-23.
- Status: aprovado.

## D-002 — Target por mapa

- Contexto: kills e deaths representam o mesmo evento sob perspectivas opostas.
- Alternativas: somar linhas de equipe, somar jogadores, somar kills e deaths.
- Decisão: somar uma vez as kills das duas linhas de equipe e validar com jogadores/deaths.
- Consequência: inconsistências bloqueiam o mapa; deaths nunca duplicam o target.
- Data: 2026-07-23.
- Status: aprovado.

## D-003 — Ligas e continuidade

- Contexto: LES, LCS e CBLOL mudaram de nomenclatura/estrutura no período.
- Alternativas: cortar históricos, manter competições separadas, mapear continuidade.
- Decisão: LVP SL e LES formam a liga canônica LES; LTA North e South de 2025 alimentam LCS e CBLOL; cruzamentos são auxiliares.
- Consequência: adapters devem preservar competição original e justificar conferência.
- Data: 2026-07-23.
- Status: aprovado.

## D-004 — Congelamento pré-série

- Contexto: mapas anteriores da série estariam disponíveis em uso real, mas introduzem uma política mais complexa.
- Alternativas: atualizar entre mapas, congelar antes da série, comparar ambas.
- Decisão: congelar todas as features antes do primeiro mapa.
- Consequência: avaliação e produção usam a mesma regra; dados intrassérie são proibidos.
- Data: 2026-07-23.
- Status: aprovado.

## D-005 — Mercado `.5`

- Contexto: linhas inteiras e asiáticas exigem push ou divisão de stake.
- Alternativas: `.5`, inteiras e `.5`, incrementos de `.25`.
- Decisão: aceitar somente `.5`.
- Consequência: push é sempre zero; outros formatos falham na validação.
- Data: 2026-07-23.
- Status: aprovado.

## D-006 — Inputs excluídos

- Contexto: patch, playoffs, bans e ordem aumentam manutenção e nem sempre possuem cobertura confiável.
- Alternativas: exigir, inferir, remover.
- Decisão: não usar esses campos como features; mantê-los apenas para auditoria quando disponíveis.
- Consequência: o modelo depende de recência para mudanças de meta e não exige esses inputs.
- Data: 2026-07-23.
- Status: aprovado.

## D-007 — Entidades insuficientes

- Contexto: fallback hierárquico permite previsão, mas o usuário não quer apostar com pouca evidência.
- Alternativas: fallback com alerta, bloquear, ignorar efeito.
- Decisão: bloquear equipe, jogador ou campeão abaixo do mínimo.
- Consequência: menor cobertura operacional; limites serão definidos pela validação.
- Data: 2026-07-23.
- Status: aprovado, limites pendentes.

## D-008 — Estratégia de liga

- Contexto: ligas possuem ritmos diferentes e tamanhos desiguais.
- Alternativas: modelos separados, pooling completo, pooling parcial.
- Decisão: pooling parcial é candidato principal, comparado a modelos separados.
- Consequência: compartilha sinal preservando diferenças regularizadas.
- Data: 2026-07-23.
- Status: aprovado.

## D-009 — Simplicidade e duração

- Contexto: decompor kills em intensidade e duração é plausível, mas adiciona fragilidade.
- Alternativas: duração obrigatória, apenas análise, challenger.
- Decisão: modelo direto simples primeiro; duração é challenger.
- Consequência: arquitetura complexa só avança com ganho comprovado.
- Data: 2026-07-23.
- Status: aprovado.

## D-010 — Métrica primária

- Contexto: o objetivo é uma distribuição, não apenas média ou uma linha.
- Alternativas: CRPS, Log Score, Brier por linhas.
- Decisão: CRPS como métrica primária, com calibração e Log Score como guardrails.
- Consequência: promoção usa distribuição completa e comparações pareadas temporais.
- Data: 2026-07-23.
- Status: aprovado.

## D-011 — Taxonomia pesquisada e revisada

- Contexto: Oracle's Elixir não fornece atributos funcionais completos de campeões.
- Alternativas: conhecimento do modelo, clustering puro, pesquisa rastreável com revisão.
- Decisão: pesquisar fontes web, revisar em lotes por função e versionar YAML.
- Consequência: nenhuma taxonomia entra ativa antes da aprovação; inferência permanece determinística.
- Data: 2026-07-23.
- Status: aprovado, conteúdo pendente.

## D-012 — Interface R–Python

- Contexto: o modelo será canônico em R e consumido futuramente pelo Streamlit.
- Alternativas: subprocesso, artefato interoperável, `plumber`.
- Decisão: API local `plumber`.
- Consequência: Python não reimplementa estatística; primeira versão terá apenas cliente de contrato.
- Data: 2026-07-23.
- Status: aprovado.

## D-013 — Scripts RStudio

- Contexto: o usuário quer testar cada etapa separadamente.
- Alternativas: arquivo único, R Markdown, scripts numerados.
- Decisão: scripts numerados chamando funções modulares compartilhadas com `targets`.
- Consequência: paridade entre execução manual e orquestrada será testada.
- Data: 2026-07-23.
- Status: aprovado.

## D-014 — Persistência e apostas

- Contexto: será necessário avaliar odds prospectivamente.
- Alternativas: não salvar, salvar sob confirmação, salvar toda consulta.
- Decisão: salvar toda consulta; aposta é marcada opcionalmente com lado e stake fixa de 1 unidade; bookmaker não é registrado.
- Consequência: calibração usa todos os casos reconciliados; ROI usa somente apostas confirmadas.
- Data: 2026-07-23.
- Status: aprovado.

## D-015 — Gate SDD

- Contexto: o projeto exige Specification-Driven Development antes de código.
- Alternativas: implementar diretamente, aprovar especificação primeiro.
- Decisão: apresentar todos os documentos SDD e aguardar aprovação explícita.
- Consequência: ambiente, testes e código de produção só começam após aprovação.
- Data: 2026-07-23.
- Status: aprovado explicitamente em 2026-07-23; implementação iniciada.

## Decisões empíricas pendentes

### D-P01 — Janela e recência

- Procedimento: comparação rolling-origin definida em `modeling-spec.md`.
- Evidência de desenvolvimento: meia-vida exponencial de 90 dias obteve CRPS médio de 4,7260 contra 4,7721 da janela fixa de 12 meses nos mesmos 2.634 mapas.
- Incerteza: diferença pareada de -0,0461, intervalo bootstrap temporal de 95% entre -0,0621 e -0,0321; ganho nos três folds.
- Segmentos: houve pequena piora pontual em CBLOL, LEC, LES e LFL, entre 0,0081 e 0,0204 de CRPS, ainda sem limiar material aprovado.
- Estudo ampliado: em nove folds de 2023–2025, 75 dias obteve o menor CRPS, mas foi indistinguível de 90 dias. Meias-vidas de 60, 75 e 90 dias formaram uma faixa de desempenho próxima; 14 e 30 dias foram materialmente piores.
- Decisão: meia-vida operacional de 60 dias; 90 dias permanece challenger.
- Data da aprovação: 2026-07-23.
- Status: aprovado e congelado para o próximo ciclo de desenvolvimento.

### D-P02 — Amostra mínima

- Procedimento: análise de estabilidade definida em `evaluation-spec.md`.
- Resultado parcial: equipe exige pelo menos 1 jogo efetivo recente para `combined_kills_per_minute`.
- Status: limite de equipe selecionado em desenvolvimento; jogadores e campeões permanecem pendentes.

### D-P03 — Taxonomia final

- Procedimento: pesquisa rastreável e revisão em lotes.
- Status: pendente de pesquisa e aprovação.

### D-P04 — Modelo campeão

- Procedimento: CRPS, guardrails, bootstrap e ablações.
- Status: pendente; nenhum campeão presumido.

### D-P05 — Gatilhos de retreinamento

- Procedimento: drift observado e custo operacional após primeira execução.
- Status: pendente de evidência.

## D-016 — Divergência entre kills e deaths

- Contexto: execuções podem gerar death sem kill adversária.
- Alternativas: invalidar o target, ignorar a conferência ou registrar alerta.
- Decisão: divergência entre player deaths e team kills gera o alerta `player_deaths_mismatch`; divergência entre player kills e team kills continua invalidando o target.
- Consequência: 661 mapas permanecem elegíveis com rastreabilidade explícita.
- Data: 2026-07-23.
- Status: implementado e coberto por teste.

## D-017 — Reinício da numeração de mapas

- Contexto: algumas equipes disputam mais de uma série no mesmo dia, inclusive partidas isoladas com mapa 1.
- Alternativas: bloquear todos os confrontos repetidos no dia ou separar pelo reinício da numeração.
- Decisão: dentro da chave liga, data e equipes, um número de mapa menor ou igual ao anterior inicia nova série; mesmo mapa no mesmo horário permanece ambíguo.
- Consequência: os 18 mapas inicialmente ambíguos foram separados de forma determinística e auditável.
- Data: 2026-07-23.
- Status: implementado e coberto por teste.

## D-018 — Holdout e blocos de desenvolvimento

- Contexto: a seleção da janela histórica precisa ocorrer sem consultar o holdout final e com cobertura das sete ligas.
- Alternativas: blocos mensais, trimestrais completos ou blocos alinhados aos períodos de competição.
- Decisão: selar jogos a partir de 2026-01-01 como holdout; usar 2025-01-01 a 2025-04-01, 2025-04-01 a 2025-07-01 e 2025-07-01 a 2025-10-01 como folds de desenvolvimento.
- Consequência: o quarto trimestre de 2025 não entra na comparação principal por não cobrir as sete ligas. O holdout permanece indisponível para seleção de janela, feature ou hiperparâmetro.
- Data: 2026-07-23.
- Status: pré-registrado antes do cálculo dos scores por janela.

## D-019 — Grade inicial de recência

- Contexto: janelas fixas precisam competir com recência contínua.
- Alternativas: grades abertas ou meias-vidas pré-registradas.
- Decisão: comparar meias-vidas de 90, 180 e 365 dias, além das janelas fixas e cortes de temporada definidos em `config/evaluation.yml`.
- Consequência: novas meias-vidas exigem nova rodada de desenvolvimento registrada e não podem ser escolhidas olhando o holdout.
- Data: 2026-07-23.
- Status: pré-registrado.

## D-020 — Registro interrompido LCK 2023

- Contexto: o CSV local contém o jogo `ESPORTSTMNT01_3408461` com 201 segundos e placar 0-0 entre Liiv SANDBOX e T1.
- Evidência: o mapa 2 concluído teve 40:43 e placar 27-12 segundo [Games of Legends](https://gol.gg/game/stats/52586/page-game/).
- Decisão: excluir exatamente esse `gameid` como `aborted_or_incomplete_capture`, sem criar limiar de duração.
- Consequência: o mapa concluído ausente não será reconstruído com dados externos; a lacuna fica registrada em `excluded_games`.
- Data: 2026-07-23.
- Status: implementado e coberto por teste.

## D-021 — Sensibilidade de recência e patches

- Contexto: a recomendação inicial de 90 dias foi validada apenas em três folds de 2025 e pode suavizar excessivamente mudanças rápidas do jogo.
- Alternativas: manter a recomendação inicial ou ampliar a validação antes de congelar a janela.
- Decisão: executar nove folds trimestrais entre 2023 e 2025 e comparar meias-vidas de 14, 30, 45, 60, 75, 90, 120, 180 e 365 dias.
- Diagnóstico: avaliar resultados por ano, fold, liga e patch, mantendo patch proibido como feature.
- Consequência: 2022 funciona como histórico inicial, 2023–2025 fornecem validações sucessivas e 2026 permanece selado.
- Data: 2026-07-23.
- Resultado: 7.586 mapas em nove folds. CRPS de 4,6803 para 60 dias, 4,6777 para 75 dias e 4,6777 para 90 dias. A diferença entre 60 e 90 dias teve intervalo bootstrap de 95% entre -0,0033 e 0,0082.
- Amostra efetiva por liga: mediana de 70,2 mapas para 60 dias, 86,2 para 75 dias e 100,0 para 90 dias.
- Patches: em 253 transições com pelo menos dez mapas por patch e liga, a mudança absoluta mediana da média de kills foi 1,60 e o percentil 90 foi 4,11.
- Status: concluído; meia-vida operacional de 60 dias aprovada em 2026-07-23.

## D-022 — Indicadores subjacentes de equipe

- Contexto: total final de kills é ruidoso e não deve ser única descrição do fenômeno.
- Procedimento: comparar blocos consecutivos de 5, 10 e 20 jogos da mesma equipe, usando apenas passado contra futuro.
- Resultado: dano por minuto, dano recebido por minuto e combined kills por minuto foram indicadores mais estáveis e relacionados à intensidade futura.
- Resultado negativo: first blood apresentou estabilidade próxima de zero; duração média passada teve baixa persistência.
- Decisão: testar primeiro intensidade, pressão ofensiva, exposição defensiva, kills por minuto e deaths por minuto. Métricas até 15 minutos entram em segunda camada.
- Consequência: cada grupo será submetido a shrinkage e ablação temporal antes de permanecer no modelo.
- Data: 2026-07-23.
- Status: aprovado para etapa preditiva, não promovido.

## D-023 — Primeira rodada de modelos simples de equipe

- Contexto: indicadores estáveis precisam provar valor preditivo incremental antes de modelos mais complexos.
- Candidatos: distribuição empírica por liga, Poisson por liga, Negative Binomial por liga e três extensões aninhadas com ritmo, ataque/defesa e dano.
- Validação: nove folds trimestrais de 2023–2025, histórico desde 2022, pesos e features com meia-vida de 60 dias, shrinkage de equipe de 20 jogos.
- Métricas: CRPS primário; Log Score, erro médio, intervalos e segmentos por liga como guardrails; bootstrap semanal pareado.
- Regra: bloco novo só permanece com ganho temporal sustentado; resultado estatisticamente incerto favorece candidato mais simples.
- Holdout: 2026 permanece selado.
- Data: 2026-07-23.
- Status: pré-registrado antes do cálculo dos scores.

## D-024 — Decomposição de ritmo sem colinearidade

- Contexto: ritmo combinado, ataque e exposição defensiva obedecem à identidade exata `ritmo = (ataque + exposição defensiva) / 2`.
- Evidência: o teste estrutural anterior à geração dos scores produziu coeficiente não identificável no primeiro fold.
- Decisão: representar a decomposição por ritmo e balanço entre ataque e exposição defensiva.
- Consequência: o modelo preserva toda a informação do par ataque/defesa sem repetir uma coluna matematicamente determinada pelas outras.
- Data: 2026-07-23.
- Status: corrigido antes da avaliação.

## D-025 — Resultado dos modelos simples de equipe

- Evidência: `reports/simple-team-models-summary.md` e artefatos `simple_team_model_*`.
- Amostra: 7.586 mapas, nove folds de 2023–2025 e sete ligas; 2026 permaneceu selado.
- Resultado: `nb_pace` obteve CRPS 4,5948 contra 4,6803 do baseline empírico.
- Incerteza: diferença pareada de -0,0854; intervalo bootstrap semanal de 95% entre -0,1150 e -0,0581.
- Segmentos: ganho médio nas sete ligas e em oito dos nove folds; LCS teve ganho pequeno de -0,0086.
- Calibração: cobertura de 90% em 91,59%; Poisson cobriu apenas 72,91% e foi rejeitado por subdispersão prática.
- Ablações: ataque/defesa piorou 0,0084 com intervalo totalmente acima de zero; dano piorou 0,0094 com intervalo incluindo empate.
- Decisão: manter `nb_pace` como líder de desenvolvimento e `nb_league` como baseline paramétrico; rejeitar os blocos adicionais nesta forma.
- Promoção: nenhuma. Ainda faltam sensibilidade ao shrinkage, amostra mínima, draft, calibração por linha e holdout.
- Data: 2026-07-23.
- Status: concluído em desenvolvimento.

## D-026 — Grade de shrinkage de equipe

- Contexto: o prior provisório de 20 jogos ainda não foi validado.
- Candidatos: 10, 20, 50 e 100 jogos equivalentes de informação média da liga.
- Modelo: `nb_pace`, vencedor da primeira rodada simples.
- Validação: nove folds de 2023–2025, meia-vida de 60 dias e holdout de 2026 selado.
- Regra: menor CRPS com guardrails; empate estatístico favorece shrinkage mais forte.
- Data: 2026-07-23.
- Status: pré-registrado antes do cálculo dos scores.

## D-027 — Shrinkage de equipe selecionado

- Evidência: `reports/team-prior-sensitivity-summary.md` e artefatos `team_prior_sensitivity_*`.
- Resultado: prior 10 obteve CRPS 4,5861; priors 20, 50 e 100 obtiveram 4,5948, 4,6127 e 4,6275.
- Incerteza: prior 20 menos prior 10 teve diferença de 0,0087 e intervalo bootstrap de 95% entre 0,0052 e 0,0122.
- Consistência: prior 10 venceu prior 20 nas sete ligas, em oito dos nove folds e nos cinco grupos de experiência mínima.
- Decisão: usar prior equivalente a 10 jogos no desenvolvimento de `nb_pace`.
- Limite operacional: continua pendente; prior estatístico não equivale a mínimo de jogos para apostar.
- Holdout: 2026 permaneceu selado.
- Data: 2026-07-23.
- Status: selecionado em desenvolvimento.

## D-028 — Revalidação do modelo simples com prior 10

- Contexto: a primeira comparação de modelos usou o prior provisório de 20 jogos.
- Procedimento: repetir os seis candidatos nos mesmos 7.586 mapas após selecionar prior 10.
- Resultado: `nb_pace` melhorou de CRPS 4,5948 para 4,5861 e manteve liderança.
- Baseline: diferença contra a distribuição empírica foi -0,0942, com intervalo bootstrap de 95% entre -0,1244 e -0,0657.
- Ablações: ataque/defesa continuou significativamente pior que ritmo; dano continuou sem ganho confiável.
- Decisão: manter `nb_pace` com prior 10 como líder de desenvolvimento.
- Holdout: 2026 permaneceu selado.
- Data: 2026-07-23.
- Status: concluído.

## D-029 — Grade de amostra mínima de equipe

- Contexto: prior estatístico e bloqueio operacional são proteções diferentes.
- Métrica: menor amostra efetiva de `combined_kills_per_minute` entre as duas equipes, com meia-vida de 60 dias.
- Grade: 1, 2, 3, 5, 8, 10, 12, 15, 20, 25 e 30 jogos efetivos.
- Diagnóstico bruto: 1, 3, 5, 10 e 20 jogos históricos.
- Comparação: `nb_pace` contra `nb_league` nos mesmos mapas.
- Regra: menor corte com ganho confiável entre elegíveis e sem ganho confiável entre bloqueados.
- Falha da regra: se não houver separação, nenhum limite será escolhido por conveniência.
- Holdout: 2026 permanece selado.
- Data: 2026-07-23.
- Status: pré-registrado antes do cálculo dos resultados por amostra.

## D-030 — Amostra mínima de equipe selecionada

- Evidência: `reports/team-sample-threshold-summary.md` e artefatos `team_sample_threshold_*`.
- Limite: pelo menos 1 jogo efetivo para cada equipe, usando meia-vida de 60 dias.
- Elegíveis: 7.484 mapas, 98,66% da validação; diferença `nb_pace - nb_league` de -0,0710.
- Incerteza elegível: intervalo bootstrap de 95% entre -0,0947 e -0,0491.
- Bloqueados: 102 mapas; diferença de -0,0787 com intervalo entre -0,2958 e 0,1276.
- Segmentos: ganho médio nos elegíveis das sete ligas; bloqueados apresentaram resultados mistos e amostras muito pequenas.
- Decisão: menos de 1 jogo efetivo ou cobertura ausente bloqueia com `Pouca amostra para X. Não apostar.`
- Escopo: limite válido somente para equipes; jogadores e campeões continuam pendentes.
- Holdout: 2026 permaneceu selado.
- Data: 2026-07-23.
- Status: selecionado em desenvolvimento e implementado.

## D-031 — Ratings dinâmicos e regressão regularizada

- A interface passa a mostrar todas as equipes das ligas suportadas. Pouca
  amostra gera aviso e bloqueio posterior, não remoção da lista.
- Ratings de ataque e defesa usam índice 100 contra pares da liga e contra
  todas as ligas. A própria equipe é excluída da referência.
- Momentum compara meias-vidas de 21 e 120 dias.
- Agressividade usa vantagem ou desvantagem de ouro aos 15 minutos.
- Snowball exige vantagem mínima de duas kills aos 15 minutos.
- Ridge, Lasso e Elastic Net selecionam `lambda` somente dentro do treino.
- Ridge com ratings, agressividade e snowball obteve CRPS 4,545573 em
  2022–2025, contra 4,562152 do V1.
- Momentum piorou a ablação e não entra no challenger congelado.
- O intervalo bootstrap do Ridge contra o V1 foi
  [-0,037189; 0,003228]. O ganho ainda não é conclusivo.
- Em 2026, usado apenas como comparação secundária, o Ridge obteve CRPS
  4,471662 contra 4,497477 do V1.
- O V1 permanece em produção. `ridge_plus_behavior` foi congelado como
  challenger prospectivo para mapas posteriores a 22/07/2026 20:02:30 UTC.
- Data: 2026-07-24.
- Status: challenger congelado, aguardando confirmação prospectiva.
# 2026-07-24 — séries temporais como diagnóstico, não como feature da V1

- Foram criadas séries semanais normalizadas para liga, equipe, target e
  ratings, com momentum, tendência, volatilidade e regime.
- O join preditivo usa somente semanas completas anteriores ao cutoff da série.
- O challenger Ridge com 16 features temporais piorou o CRPS de 4,5456 para
  4,5681 nos folds 2022–2025.
- A comparação secundária de 2026 também piorou, de 4,4717 para 4,4909.
- Decisão: manter o tracking no painel para diagnóstico e pesquisa; não alterar
  o modelo congelado.

## D-032 — Deploy atualizado e coleta prospectiva

- A interface atualizada foi publicada no Streamlit Community Cloud.
- O deploy usa o projeto Supabase exclusivo `modelo-abates-lol`.
- O papel `lol_kills_writer` possui somente `SELECT` e `INSERT` no histórico.
- A conexão usa o Transaction Pooler e fica somente nos Secrets do Streamlit.
- Uma previsão pública com status `ok` foi gravada e confirmada diretamente em
  `lol_kills.prediction_events`.
- A coleta prospectiva começou em 2026-07-25 para mapas posteriores ao cutoff
  congelado do challenger.
- Status: concluído.

## D-033 — Decisão de aposta posterior à previsão

- A previsão continua sendo salva no momento do cálculo para evitar viés de
  seleção na avaliação prospectiva.
- A decisão de apostar ocorre somente depois que as probabilidades são
  apresentadas.
- Over, Under e Não apostar são gravados em evento separado, ligado à previsão.
- Cada previsão aceita no máximo uma decisão e o histórico permanece
  append-only.
- Over e Under exigem a odd correspondente e registram stake fixa de 1 unidade.
- Status: aprovado e implementado.

## D-034 — Retirada de jogadores do modelo operacional

- O CSV de 2026 foi atualizado no manifesto com hash SHA-256
  `44841992EE25535FD89AA6065FB6A506C59896E2A09C695B13FA4FC666655B6E`.
- Identidade, histórico, estabilidade de elenco e interações jogador–campeão
  foram retirados do modelo, da inferência, dos bloqueios e do bundle público.
- As linhas de jogador da fonte permanecem somente para auditar kills e
  identificar os campeões e posições do draft.
- A interface solicita apenas equipes, sides e cinco campeões por posição.
- O V1 reconstruído continua sendo `nb_pace_draft`, com sinais de ritmo das
  equipes e atributos funcionais das composições.
- No holdout atualizado de 2026, com 1.645 mapas, o V1 obteve CRPS 4,4440,
  Log Score 3,4720 e cobertura de 90% igual a 90,82%.
- Na linha 24,5, o Brier foi 0,2085, o Log Loss foi 0,6046 e o erro de
  calibração foi 0,0243.
- Nos folds de 2022–2025, o V1 obteve CRPS 4,5622, contra 4,5718 do modelo
  com arquétipos funcionais ampliados e 4,5823 do modelo com efeitos explícitos
  de equipe e adversário.
- Cutoff do bundle reconstruído: 2026-07-25 17:35:45 UTC.
- Status: aprovado, implementado e reconstruído.
