"""add Highlight.context

Revision ID: a1b2c3d4e5f6
Revises: ecb4065de575
Create Date: 2026-03-09 10:00:00.000000

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'a1b2c3d4e5f6'
down_revision = 'db5e31a0233d'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        'highlights',
        sa.Column('context', sa.Text(), nullable=True),
    )


def downgrade():
    with op.batch_alter_table('highlights') as batch_op:
        batch_op.drop_column('context')
