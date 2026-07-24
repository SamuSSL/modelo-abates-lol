# Avaliação de jogadores e draft

## Decisão

O bloco simples de draft foi selecionado. O bloco de jogadores foi
rejeitado como variável preditiva da V1.

## Resultado

| Modelo | CRPS |
|---|---:|
| Ritmo + draft | 4,5622 |
| Ritmo + jogadores + draft | 4,5755 |
| Ritmo | 4,5861 |
| Ritmo + jogadores | 4,6003 |

O draft melhorou o ritmo em 0,0240 ponto de CRPS. O intervalo bootstrap
de 95% foi de -0,0403 a -0,0080, com 99,86% das reamostragens favoráveis.
O ganho apareceu em oito de nove períodos e seis de sete ligas. Na LEC,
a degradação média foi pequena, 0,0064.

Adicionar jogadores ao draft piorou 0,0133, com intervalo inteiramente
acima de zero. O bloco isolado de jogadores também piorou. Isso não
prova que jogadores nunca importam; mostra que estas médias históricas
não acrescentaram previsão confiável além do ritmo de equipe.

Um ensemble 50/50 entre ritmo e draft obteve CRPS 4,5657. A diferença
contra draft isolado foi 0,0036, com intervalo de -0,0043 a 0,0115.
Foi rejeitado porque não demonstrou ganho.

## Leitura simples

O estilo recente das equipes explica a maior parte do sinal estável.
A composição dos dez campeões acrescenta uma melhora pequena, mas
consistente. As estatísticas individuais testadas adicionaram ruído.
