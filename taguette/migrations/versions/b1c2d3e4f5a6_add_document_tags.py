"""add document_tags junction table

Revision ID: b1c2d3e4f5a6
Revises: a1b2c3d4e5f6
Create Date: 2026-03-20 10:00:00.000000

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'b1c2d3e4f5a6'
down_revision = 'a1b2c3d4e5f6'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'document_tags',
        sa.Column('document_id', sa.Integer(),
                  sa.ForeignKey('documents.id', ondelete='CASCADE'),
                  primary_key=True, nullable=False),
        sa.Column('tag_id', sa.Integer(),
                  sa.ForeignKey('tags.id', ondelete='CASCADE'),
                  primary_key=True, nullable=False),
    )
    op.create_index('ix_document_tags_document_id', 'document_tags',
                    ['document_id'])
    op.create_index('ix_document_tags_tag_id', 'document_tags', ['tag_id'])


def downgrade():
    op.drop_index('ix_document_tags_tag_id', table_name='document_tags')
    op.drop_index('ix_document_tags_document_id', table_name='document_tags')
    op.drop_table('document_tags')
