# Rodada de pesquisa do fenômeno de kills

Data da execução: 2026-07-26.

## Pergunta

O objetivo desta rodada foi representar melhor a distribuição de kills para
linhas de Over e Under. O total foi separado conceitualmente em:

```text
total de kills = duração do mapa × intensidade de kills por minuto
```

Todas as features foram congeladas antes da série. Jogadores não foram usados.
O V1 público não foi alterado durante a pesquisa.

## Novos sinais

Foram construídos históricos com meia-vida de 30, 60 e 120 dias:

- kills e deaths por minuto;
- ritmo combinado do confronto;
- kills até 10 e 15 minutos;
- ritmo depois de 15 minutos;
- dano causado e recebido por minuto;
- assistências por minuto;
- atividade de torres, dragões, arautos e barões;
- tamanho da vantagem aos 15 minutos;
- conversão de vantagem em vitória;
- tempo para encerrar quando à frente;
- capacidade de prolongar quando atrás;
- nível, tendência, razão e desequilíbrio entre janelas.

Também foram mantidos os ratings existentes de ataque e defesa, agressividade,
snowball, momentum e os atributos funcionais do draft.

Todos os históricos usam decaimento exponencial e shrinkage para a média da
liga. Amostras pequenas, portanto, não recebem o mesmo peso de amostras grandes.

## O que mais explica kills antes do jogo

Correlações ajustadas por liga e temporada:

| Sinal pré-jogo | Correlação com kills totais |
|---|---:|
| Ataque contra defesa adversária na liga | 0,156 |
| Intensidade histórica longa | 0,148 |
| Intensidade histórica média | 0,146 |
| Intensidade histórica curta | 0,135 |
| Ritmo depois de 15 minutos, janela longa | 0,129 |
| Ritmo depois de 15 minutos, janela média | 0,126 |
| Agressividade quando à frente | 0,115 |
| Pressão global de ataque contra defesa | 0,114 |
| Agressividade quando atrás | 0,110 |
| Dano histórico por minuto | 0,100 |
| Atividade de assistências | 0,098 |
| Ritmo inicial | 0,097 |
| Frontline do draft | 0,084 |

Essas correlações são associações preditivas, não provas de causalidade.

O ritmo histórico é mais informativo para kills por minuto do que para duração.
A intensidade média teve correlação ajustada de 0,193 com kills por minuto. O
melhor sinal de duração foi o desequilíbrio de intensidade entre as equipes,
com correlação ajustada de aproximadamente -0,099.

## Duração

A correlação observada entre duração do próprio mapa e kills totais foi 0,38.
Ela não pode ser usada diretamente na previsão porque ainda não é conhecida.

O modelo anterior previa quase a mesma duração para todos os mapas. A nova
regressão:

- aumentou o desvio previsto médio para perto da dispersão real;
- atingiu cobertura de 90% igual a 89,0% no desenvolvimento;
- melhorou a correlação entre duração prevista e observada de 0,085 para 0,118
  com as features enriquecidas;
- em 2026, o XGBoost de duração alcançou correlação 0,128.

Apesar disso, trocar a duração básica pela enriquecida piorou ligeiramente a
distribuição final de kills. A duração enriquecida ficou como diagnóstico.

## Dependência entre duração e intensidade

O coeficiente médio estimado foi -0,160. Em termos simples, mapas mais longos
tendem a produzir kills em ritmo menor. Isso confirma que multiplicar uma
duração e uma intensidade independentes é uma simplificação ruim.

O modelo acoplado respeita essa relação: cada duração simulada gera uma
intensidade compatível antes da construção da PMF final.

## Validação temporal de 2023 a 2025

Foram previstos 7.586 mapas em nove folds.

| Modelo | CRPS | Log Score | MAE | RMSE | Cobertura 90% |
|---|---:|---:|---:|---:|---:|
| Ensemble V1 + acoplado | 4,5316 | 3,4866 | 6,407 | 8,139 | 93,0% |
| Ensemble V1 + Ridge | 4,5401 | 3,4884 | 6,421 | 8,155 | 92,6% |
| Duração × intensidade acopladas | 4,5483 | 3,4926 | 6,418 | 8,160 | 93,4% |
| Ridge com históricos e draft | 4,5563 | 3,4939 | 6,432 | 8,177 | 93,1% |
| V1 atual | 4,5622 | 3,4924 | 6,459 | 8,198 | 91,7% |
| XGBoost com features novas | 4,5775 | 3,4979 | 6,481 | 8,216 | 90,0% |

O ensemble V1 + Ridge teve diferença de CRPS de -0,0220 contra o V1. O
intervalo bootstrap semanal de 95% foi de -0,0325 a -0,0119.

## Comparação secundária em 2026

Foram previstos 1.710 mapas. Esta comparação não pode selecionar um modelo,
pois 2026 já foi consultado durante o desenvolvimento.

| Modelo | CRPS | Log Score | MAE | RMSE | Cobertura 90% |
|---|---:|---:|---:|---:|---:|
| Ensemble V1 + Ridge | 4,4836 | 3,4804 | 6,400 | 8,052 | 92,0% |
| Ridge com históricos e draft | 4,4946 | 3,4842 | 6,410 | 8,066 | 92,6% |
| V1 atual reconstruído | 4,4959 | 3,4836 | 6,417 | 8,074 | 90,4% |
| Duração × intensidade acopladas | 4,5021 | 3,4865 | 6,424 | 8,082 | 93,1% |
| XGBoost com features novas | 4,5463 | 3,4927 | 6,478 | 8,152 | 90,5% |

O ensemble V1 + Ridge teve diferença de CRPS de -0,0123 contra o V1. O
intervalo bootstrap de 95% foi de -0,0282 a 0,0022.

## Linhas de Over e Under

Na média das 14 linhas entre 18,5 e 44,5:

| Período | Modelo | Brier | Log Loss |
|---|---|---:|---:|
| Desenvolvimento | V1 | 0,14764 | 0,45464 |
| Desenvolvimento | Ensemble V1 + Ridge | 0,14684 | 0,45223 |
| 2026 | V1 | 0,14964 | 0,46199 |
| 2026 | Ensemble V1 + Ridge | 0,14920 | 0,46043 |

O ganho existe, mas é pequeno. A calibração varia por linha. Por isso, não há
base para declarar que o challenger já está pronto para apostas.

## Ablações

- Históricos multiescala isolados pioraram o Ridge.
- Ratings de ataque, defesa e comportamento acrescentaram sinal pequeno.
- Arquétipos de draft ajudaram no desenvolvimento.
- Momentum continuou instável.
- A duração enriquecida melhorou minutos, mas não melhorou kills.
- XGBoost foi pior no desenvolvimento e em 2026.
- A decomposição melhorou CRPS no desenvolvimento, mas não confirmou em 2026.
- O ensemble foi mais estável que qualquer challenger isolado.

## Decisão

O V1 continua em produção.

O ensemble com 50% do V1 e 50% do Ridge de equipe e draft foi congelado como
modelo-sombra `kill-market-shadow-c2e3e7efd938`. Somente mapas posteriores a
2026-07-25 17:35:44 UTC podem servir como confirmação prospectiva limpa.

O modelo-sombra não deve aparecer ao usuário nem substituir probabilidades
enquanto não houver amostra prospectiva suficiente e melhora conjunta em CRPS,
Log Score, Brier e calibração por linha.
