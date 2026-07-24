# Sensibilidade do shrinkage de equipe

## Pergunta

Quanto o modelo deve puxar uma equipe para a média da liga quando seu histórico
recente é curto ou extremo?

Foram comparados priors de 10, 20, 50 e 100 jogos. Todos usaram o modelo
Negative Binomial com ritmo, 7.586 mapas e os mesmos nove folds de 2023–2025.
O ano de 2026 continuou fechado.

## Resultado

| Prior equivalente | CRPS | Log Score | Cobertura 90% |
|---:|---:|---:|---:|
| 10 jogos | 4,5861 | 3,4981 | 91,60% |
| 20 jogos | 4,5948 | 3,5001 | 91,59% |
| 50 jogos | 4,6127 | 3,5040 | 91,43% |
| 100 jogos | 4,6275 | 3,5075 | 91,39% |

Prior de 10 jogos venceu. Comparado a ele, prior 20 piorou 0,0087 de CRPS,
com intervalo bootstrap de 95% entre 0,0052 e 0,0122. Priors 50 e 100
pioraram ainda mais. Portanto, não houve empate que acionasse a preferência
por shrinkage mais forte.

## Explicação simples

Prior 10 funciona como dez jogos virtuais de uma equipe média da liga. Se uma
equipe possui poucos jogos, essa média pesa bastante. Conforme chegam jogos
reais, o histórico da própria equipe ganha espaço.

Prior 100 equivale a colocar cem jogos virtuais médios na conta. Isso protege
contra extremos, mas também apaga diferenças reais entre equipes. Os dados
mostraram que 20, 50 e 100 estavam suavizando demais o ritmo.

Prior 10 não significa liberar aposta depois de dez jogos. Shrinkage é proteção
estatística dentro do cálculo. O bloqueio operacional por pouca amostra é uma
decisão separada.

## Consistência

Prior 10 venceu prior 20 nas sete ligas e em oito dos nove folds. A única
exceção foi 2025 Q1, onde prior 20 melhorou 0,0027 de CRPS.

Também venceu em todos os grupos de experiência mínima:

| Menor histórico entre as equipes | Mapas | CRPS prior 10 | CRPS prior 20 |
|---|---:|---:|---:|
| 0–4 jogos | 175 | 4,6386 | 4,6542 |
| 5–9 jogos | 150 | 4,3309 | 4,3455 |
| 10–19 jogos | 305 | 5,0934 | 5,1128 |
| 20–49 jogos | 847 | 4,5058 | 4,5166 |
| 50 ou mais | 6.109 | 4,5767 | 4,5842 |

Os grupos pequenos possuem poucos mapas e misturam ligas e épocas diferentes.
Esses números não bastam para escolher o limite de bloqueio. Eles apenas mostram
que aumentar o prior não resolveu a incerteza por pouca amostra.

## Decisão

Prior de 10 jogos passa a ser o padrão de desenvolvimento. Priors 20, 50 e 100
são rejeitados para `nb_pace`.

Nenhum limite mínimo de jogos foi aprovado. Próxima análise deve medir quando
o sinal específico da equipe passa a superar de forma confiável uma previsão
que conhece apenas a liga.
