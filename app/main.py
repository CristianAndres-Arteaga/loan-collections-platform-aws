from fastapi import FastAPI

app = FastAPI(title="Loan Collections API")


@app.get("/health")
def health_check():
    return {"status": "ok"}