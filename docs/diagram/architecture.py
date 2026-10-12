"""Diagrama de arquitectura de loan-collections-platform-aws.

Genera docs/diagram/architecture.png con los íconos oficiales de AWS.

    pip install -r docs/diagram/requirements.txt   # requiere Graphviz (apt install graphviz)
    python docs/diagram/architecture.py
"""

from pathlib import Path

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import EC2, ECR, EC2AutoScaling
from diagrams.aws.database import ElastiCache, RDSPostgresqlInstance
from diagrams.aws.integration import SNS
from diagrams.aws.management import Cloudwatch
from diagrams.aws.network import ALB, CloudFront, Endpoint
from diagrams.aws.security import KMS
from diagrams.aws.storage import S3
from diagrams.onprem.ci import GithubActions
from diagrams.onprem.client import Users

OUTPUT = Path(__file__).with_name("architecture")

GRAPH_ATTR = {
    "label": "Loan Collections Platform on AWS",
    "labelloc": "t",
    "fontsize": "26",
    "fontname": "Helvetica-Bold",
    "pad": "0.5",
    "nodesep": "0.9",
    "ranksep": "1.3",
    "splines": "spline",  # con "ortho" Graphviz separa las etiquetas de sus flechas
    "bgcolor": "white",
}
NODE_ATTR = {"fontsize": "13", "fontname": "Helvetica"}
EDGE_ATTR = {"fontsize": "12", "fontname": "Helvetica", "color": "#545B64", "fontcolor": "#232F3E"}

# Colores de los grupos según la guía de diagramas de AWS.
CLOUD_ATTR = {"bgcolor": "#FFFFFF", "pencolor": "#232F3E", "fontcolor": "#232F3E", "fontsize": "15"}
REGION_ATTR = {"bgcolor": "#F7FBFE", "pencolor": "#00A4A6", "fontcolor": "#007A7C", "style": "dashed", "fontsize": "14"}
VPC_ATTR = {"bgcolor": "#F2F9F2", "pencolor": "#248814", "fontcolor": "#248814", "fontsize": "14"}
PUBLIC_ATTR = {"bgcolor": "#E9F3E6", "pencolor": "#7AA116", "fontcolor": "#3F6B0F"}
PRIVATE_ATTR = {"bgcolor": "#E6F2F8", "pencolor": "#147EBA", "fontcolor": "#0F5E8C"}
GLOBAL_ATTR = {"bgcolor": "#F5F0FA", "pencolor": "#8C4FFF", "fontcolor": "#5B2DB3"}

with Diagram(
    "",
    filename=str(OUTPUT),
    outformat="png",
    direction="LR",
    show=False,
    graph_attr=GRAPH_ATTR,
    node_attr=NODE_ATTR,
    edge_attr=EDGE_ATTR,
):
    users = Users("Users\n(browser)")
    ci = GithubActions("GitHub Actions\nOIDC, no keys")

    with Cluster("AWS Cloud", graph_attr=CLOUD_ATTR):
        with Cluster("Global edge", graph_attr=GLOBAL_ATTR):
            cdn = CloudFront("CloudFront\nHTTPS + IP filter")

        with Cluster("Region us-east-2", graph_attr=REGION_ATTR):
            frontend = S3("S3 (private)\nstatic frontend")

            with Cluster("VPC 10.0.0.0/16 · 2 AZs", graph_attr=VPC_ATTR):
                with Cluster("Public subnets", graph_attr=PUBLIC_ATTR):
                    alb = ALB("Application\nLoad Balancer")
                    bastion = EC2("Bastion\nSSM only")

                with Cluster("Private app subnets", graph_attr=PRIVATE_ATTR):
                    app = EC2AutoScaling("Auto Scaling group\nEC2 · Docker\nFastAPI")
                    endpoints = Endpoint("VPC endpoints\n(no NAT)")

                with Cluster("Private data subnets", graph_attr=PRIVATE_ATTR):
                    cache = ElastiCache("ElastiCache\nValkey · TLS")
                    db = RDSPostgresqlInstance("RDS PostgreSQL\nPITR · Multi-AZ\n(optional)")

            registry = ECR("ECR\nscanned images")
            logs = Cloudwatch("CloudWatch\nlogs + alarms")
            alerts = SNS("SNS\nemail alerts")
            kms = KMS("KMS")

    # Camino de la petición: se lee de izquierda a derecha.
    users >> Edge(label="HTTPS") >> cdn
    cdn >> Edge(label="/*  OAC") >> frontend
    cdn >> Edge(label="/api/*  HTTP\n+ secret header") >> alb
    alb >> Edge(label=":8080") >> app
    app >> Edge(label="SQL") >> db
    app >> Edge(label="cache-aside\nfail-open", style="dashed") >> cache

    # Plano de operación: no debe deformar el camino principal.
    app >> endpoints
    endpoints >> Edge(label="image pull") >> registry
    endpoints >> Edge(label="logs") >> logs
    logs >> Edge(label="alarm") >> alerts
    db >> Edge(label="encrypted at rest", style="dotted") >> kms
    bastion >> Edge(label="SSM tunnel", style="dashed", constraint="false") >> db
    cdn >> Edge(style="invis") >> bastion
    ci >> Edge(label="build · scan · push") >> registry
