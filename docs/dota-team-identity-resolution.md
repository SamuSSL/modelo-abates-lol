# Resolução de identidade OpenDota do Dota 2

## Resultado da primeira coleta

O registro foi construído com os times presentes no catálogo operacional e consultou o endpoint OpenDota `/teams/{team_id}/players`. Cada resposta foi preservada no projeto fonte com endpoint, parâmetros, horário UTC de coleta, status HTTP, SHA-256 e versão de schema.

Resumo da coleta histórica do registro:

| Situação | Times |
|---|---:|
| Cinco membros atuais observados | 9 |
| Membros atuais incompletos | 34 |
| Sem evidência de roster | 137 |
| Total no registro | 180 |

Os dados de roster continuam preservados no registro bruto para auditoria, mas não fazem parte da decisão operacional da interface.

## Hokori

| ID OpenDota | Último jogo histórico | Membros atuais observados | Situação |
|---|---|---:|---|
| `10150267` | 17/06/2026 | 2/5 | `current_membership_incomplete` |
| `7119077` | 13/04/2026 | 4/5 | `current_membership_incomplete` |

O sistema escolhe automaticamente o ID com evidência histórica mais recente antes do cutoff e mantém os dois IDs separados. A checagem de elenco fica fora do modelo e deve ser feita manualmente antes de qualquer uso.

## Regra operacional

- Um nome visual, como `Hokori`, aparece uma vez no seletor principal.
- O ID OpenDota mais recente elegível é mostrado no rótulo e nos metadados da previsão.
- A escolha automática respeita o horário planejado e nunca usa um `last_seen` posterior ao cutoff.
- O seletor não exibe roster, titulares, reservas ou treinadores.
- Idade do ID e histórico de roster são informações auxiliares, não critérios de bloqueio.
- A comparação manual só fica bloqueada quando nenhum ID OpenDota elegível é encontrado antes do cutoff.

## Limitação que permanece

`/teams/{team_id}/players` é uma fotografia do que o OpenDota reportou no momento da coleta. A resposta não garante que os cinco jogadores participarão do próximo mapa da PGL. Por isso, esse dado permanece apenas como evidência de auditoria e não bloqueia a simulação.

O usuário deve verificar manualmente se o elenco atual corresponde ao histórico antes de comparar a cotação com uma soft book. Se a troca de jogadores for grande, a recomendação operacional é não apostar até existir histórico suficiente do novo grupo.

## Atualização do registro

A atualização deve ser executada no projeto fonte Dota 2, que preserva o cache bruto das respostas OpenDota:

```powershell
cd "C:\Users\Samuel\Documents\Modelo Abates Dota 2"
py -3 scripts/74_build_dota_team_identity_registry.py `
  --catalog-path "C:\Users\Samuel\Documents\Modelo Abates LoL\app_data\dota_ui_catalog.json" `
  --refresh-live
Copy-Item artifacts/team_identity/dota_team_identity_registry.json `
  "C:\Users\Samuel\Documents\Modelo Abates LoL\app_data\dota_team_identity_registry.json"
```

O comando consulta apenas os IDs do catálogo operacional, usa cache retomável e não grava a chave do BettingIsCool. Depois da cópia, a suíte `py -3 -m pytest tests_python -q` deve ser executada no projeto do Streamlit.
