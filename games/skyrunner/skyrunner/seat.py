"""`python -m skyrunner.seat --connect HOST:PORT --role copilot|interceptor [--graphics low|medium|high]`"""
from .render.remote import main

if __name__ == "__main__":
    main()
