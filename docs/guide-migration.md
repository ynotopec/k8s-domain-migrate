# Guide de migration d'Ingress vers un nouveau domaine

Ce guide complète la documentation principale en détaillant une procédure étape par étape pour cloner des Ingress vers un nouveau domaine racine à l'aide de `ingress-duplicate-ai-dev.sh`.

## 1. Préparation de l'environnement

1. Vérifiez que `kubectl`, `jq`, `yq` et `curl` sont disponibles sur votre poste.
2. Assurez-vous que le contexte `kubectl` pointe vers le cluster cible.
3. Exportez, si nécessaire, les variables d'environnement décrites dans la [documentation principale](../README.md#variables-denvironnement-cles).

## 2. Exécution d'un plan

```bash
NAMESPACE_SEL="^ai-.*" LABEL_SEL="environment=prod" ./ingress-duplicate-ai-dev.sh --plan
```

Cette commande :

- Limite la recherche aux namespaces commençant par `ai-`.
- Filtre les Ingress portant le label `environment=prod`.
- Génère les manifestes clonés dans le répertoire `OUT_DIR` (par défaut `./ingress-aidev-out`).

Consultez les fichiers `plan-files.txt` et `before-inventory.txt` pour vérifier le périmètre du plan.

## 3. Validation du plan

1. Inspectez les manifestes générés (`*.yaml`) pour confirmer la réécriture des hôtes et l'absence de champs gérés par le serveur.
2. Lisez `http-probes.md` si des probes HTTP ont été exécutées.
3. Si `OPENAI_API_*` est configuré, vérifiez `llm-plan-summary.md` pour un résumé synthétique.

## 4. Application des ressources

Lorsque le plan est validé, appliquez les manifestes :

```bash
./ingress-duplicate-ai-dev.sh --apply
```

Le script utilise `kubectl apply --server-side --force-conflicts` pour créer ou mettre à jour les Ingress dupliqués. Surveillez la sortie pour détecter tout conflit ou échec d'application.

## 5. Rollback

En cas de besoin, supprimez les Ingress dupliqués via :

```bash
./ingress-duplicate-ai-dev.sh --rollback
```

Cela cible les ressources portant l'annotation `duplicated-for=ai-dev`. Vérifiez `after-ingresses.txt` pour confirmer le retour à l'état initial.

## 6. Diagramme de référence

Pour rappel, le flux général est résumé dans le diagramme Mermaid ci-dessous :

```mermaid
flowchart TD
    A[Collecte des Ingress via kubectl] --> B[Filtrage par namespaces et labels]
    B --> C[Réécriture des hôtes vers le domaine cible]
    C --> D[Nettoyage des champs gérés par le serveur]
    D --> E[Génération des manifestes YAML clonés]
    E --> F{Mode}
    F -- --plan --> G[Inventaire et artefacts de plan]
    F -- --apply --> H[Application server-side des manifestes]
    H --> I[Validation optionnelle par probes HTTP]
```

Ce diagramme peut être copié dans n'importe quel outil compatible Mermaid pour obtenir un rendu graphique.

