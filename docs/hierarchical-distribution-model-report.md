# Modelo hierárquico não linear da distribuição de kills

Data da avaliação: 2026-07-26.

## Objetivo

Testar se relações não lineares, efeitos hierárquicos de equipe e dispersão
específica por partida melhoram as probabilidades de Over e Under.

O modelo foi desenvolvido como challenger. O V1 permaneceu inalterado.

## Arquitetura

### Média de kills

A média condicional usa uma regressão Negative Binomial com:

- curvas cúbicas regularizadas;
- interações não lineares;
- interceptos por liga;
- efeito aleatório encolhido para a equipe azul;
- efeito aleatório encolhido para a equipe vermelha.

Os sinais incluem intensidade histórica, ataque contra defesa adversária,
desequilíbrio do confronto, ritmo pós-15 minutos, agressividade, snowball e
atributos funcionais do draft.

### Dispersão

Uma segunda regressão estima quanto a variância de cada mapa deve superar a
variância de Poisson. Ela usa:

- média prevista;
- intensidade e desequilíbrio;
- snowball;
- dificuldade, burst e scaling do draft;
- liga.

A dispersão não foi aprendida usando resíduos do mesmo ajuste. Dentro de cada
fold:

1. o modelo da média foi treinado no bloco temporal inicial;
2. ele previu um bloco posterior;
3. a dispersão foi aprendida com esses erros futuros;
4. um bloco ainda mais recente escolheu o peso da dispersão local;
5. somente depois a média foi reajustada com todo o treino permitido.

### Hierarquia

Os efeitos de equipe usam penalização equivalente a shrinkage. Equipes com
pouca evidência ficam próximas de efeito zero. Equipes não vistas recebem
efeito zero na inferência.

## Testes

Foram adicionados testes para:

- curvas, interações e componentes hierárquicos;
- dispersões diferentes entre mapas;
- PMFs válidas e normalizadas;
- estabilidade para equipes novas;
- ausência de valores inválidos.

Todos os testes novos e antigos passaram.

## Desenvolvimento de 2023 a 2025

A avaliação contém 7.586 mapas em nove folds.

| Modelo | CRPS | Log Score | MAE | RMSE | Cobertura 90% |
|---|---:|---:|---:|---:|---:|
| GAM hierárquico, theta global | 4,5594 | 3,4937 | 6,429 | 8,190 | 91,46% |
| GAM sem efeitos de equipe | 4,5597 | 3,4940 | 6,429 | 8,190 | 91,50% |
| GAM hierárquico distribucional | 4,5598 | 3,4940 | 6,429 | 8,190 | 91,50% |
| V1 | 4,5622 | 3,4924 | 6,459 | 8,198 | 91,73% |

O ganho de CRPS do modelo completo contra o V1 foi apenas -0,0024. O intervalo
bootstrap semanal de 95% foi de -0,0244 a 0,0195. O resultado é compatível com
ganho, empate ou piora.

O Log Score do V1 continuou melhor.

## Comparação secundária de 2026

A avaliação contém 1.710 mapas.

| Modelo | CRPS | Log Score | MAE | RMSE | Cobertura 90% |
|---|---:|---:|---:|---:|---:|
| V1 | 4,4959 | 3,4836 | 6,417 | 8,074 | 90,41% |
| GAM sem efeitos de equipe | 4,5412 | 3,5019 | 6,442 | 8,127 | 88,36% |
| GAM hierárquico distribucional | 4,5412 | 3,5019 | 6,442 | 8,127 | 88,36% |
| GAM hierárquico, theta global | 4,5469 | 3,5076 | 6,442 | 8,127 | 87,49% |

A diferença de CRPS do modelo completo contra o V1 foi +0,0453. O intervalo
bootstrap de 95% foi de +0,0027 a +0,0958. A piora foi material.

O modelo piorou principalmente em LCS, LES, LFL e LPL.

## Over e Under

Na média das 14 linhas entre 18,5 e 44,5:

| Período | Modelo | Brier | Log Loss |
|---|---|---:|---:|
| Desenvolvimento | V1 | 0,14764 | 0,45464 |
| Desenvolvimento | GAM distribucional | 0,14755 | 0,45487 |
| 2026 | V1 | 0,14964 | 0,46199 |
| 2026 | GAM distribucional | 0,15128 | 0,46705 |

Na linha 24,5 de 2026, o modelo atribuiu 72,21% ao Over, enquanto a frequência
observada foi 68,30%. O Brier ficou em 0,2121 contra 0,2104 do V1.

## O que o modelo aprendeu

- Em sete dos nove folds, o tuning escolheu peso zero para dispersão local.
- Nos outros dois folds, escolheu apenas 25%.
- Os efeitos aleatórios de equipe tiveram complexidade efetiva média abaixo de
  0,5 e significância praticamente nula.
- A versão com e sem efeitos de equipe produziu resultados quase idênticos.
- A maior parte das curvas teve complexidade efetiva abaixo de 1.
- Frontline e ataque contra defesa adversária foram os smooths mais usados,
  mas ainda com relações próximas de lineares.

Em termos simples, o modelo recebeu liberdade para criar curvas e distribuições
diferentes, mas os dados pediram que quase toda essa liberdade fosse encolhida.

## Decisão

O modelo foi implementado e falsificado corretamente.

Ele não será promovido, congelado como modelo-sombra nem publicado no
Streamlit. O V1 e o ensemble prospectivo anterior permanecem inalterados.

Aumentar complexidade, trocar GAM por MCMC ou elevar o número de iterações não
corrige a ausência de sinal incremental demonstrada nesta especificação.
