"""Create the login, organization, project, DSN key and API token.

Run once through `manage.py shell` with the OBS_GT_* environment set. Idempotent.
Uses GlitchTip's own models, the same ones its bootstrap_dev command uses, so the
result is a real user rather than the fixed dev credentials that command writes.
"""
import json
import os
import uuid

from allauth.account.models import EmailAddress

from apps.api_tokens.models import APIToken
from apps.organizations_ext.models import Organization
from apps.projects.models import Project, ProjectKey
from apps.teams.models import Team
from apps.users.models import User

SCOPES = [
    "project:read", "project:write", "project:admin", "project:releases",
    "team:read", "team:write", "team:admin",
    "event:read", "event:write", "event:admin",
    "org:read", "org:write", "org:admin",
    "member:read", "member:write", "member:admin",
]

email = os.environ["OBS_GT_EMAIL"]
password = os.environ["OBS_GT_PASSWORD"]
token_value = os.environ["OBS_GT_TOKEN"]
public_key = uuid.UUID(os.environ["OBS_GT_PUBLIC_KEY"])
slug = os.environ.get("OBS_GT_SLUG", "dev")

user = User.objects.filter(email=email).first()
if user is None:
    user = User.objects.create_superuser(email=email, password=password)
else:
    user.set_password(password)
    user.save()
EmailAddress.objects.get_or_create(user=user, email=email, defaults={"primary": True, "verified": True})

org, _ = Organization.objects.get_or_create(slug=slug, defaults={"name": slug})
if not org.users.filter(pk=user.pk).exists():
    org.add_user(user)

project, _ = Project.objects.get_or_create(slug="app", organization=org, defaults={"name": "app"})
team, _ = Team.objects.get_or_create(slug="dev", organization=org)
team.members.add(org.organization_users.get(user=user))
team.projects.add(project)

key = ProjectKey.objects.filter(project=project).first()
if key is None:
    key = ProjectKey.objects.create(project=project)
ProjectKey.objects.filter(pk=key.pk).update(public_key=public_key)

token = APIToken.objects.filter(label="observability", user=user).first()
if token is None:
    token = APIToken.objects.create(user=user, label="observability")
    token.add_permissions(SCOPES)
APIToken.objects.filter(pk=token.pk).update(token=token_value)

print("OBS_RESULT " + json.dumps({"project_id": project.pk, "org": org.slug}))
