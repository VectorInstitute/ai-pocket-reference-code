# AI Pocket Reference - Supplementary Code

This repository houses supplementary code and Jupyter notebooks that accompany the
[AI Pocket Reference](https://github.com/VectorInstitute/ai-pocket-reference) project.

## Repository Structure

The repository is organized by main AI domains to align with the AI Pocket Reference
project:

```bash
notebooks/
├── fundamentals/
├── nlp/
├── cv/
├── rl/
├── fl/
└── responsible_ai/
```

Each directory contains supplementary Jupyter notebooks for their corresponding
Pocket References The notebooks follow the same naming convention as their pocket
reference counterparts (without the .md extension). For example:

- `notebooks/nlp/lora.ipynb` corresponds to the LoRA pocket reference

This naming convention makes it easy to find the associated code examples and
implementations for any given pocket reference.

## Running the Notebooks

You can run these notebooks in two ways:

- Through Google Colab: Follow the Colab links provided directly in the pocket
  reference
- Locally:

  ```bash
  # Clone the repository
  git clone https://github.com/VectorInstitute/ai-pocket-reference-code.git
  cd ai-pocket-reference-code

  # Set up your environment
  pip install -r requirements.txt

  # Launch Jupyter
  jupyter lab
  ```

## Contributing

We welcome contributions of new notebooks and improvements to existing ones!
Please see our [CONTRIBUTING.md](CONTRIBUTING.md) guide for details.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file
for details.

---

Maintained by Vector AI Engineering
