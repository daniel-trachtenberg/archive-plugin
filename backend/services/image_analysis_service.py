import os
import logging
import torch
import open_clip
from PIL import Image
import io
import random

# Initialize CLIP model once at module load time
try:
    model_name = "ViT-B-32"  # Lightweight model
    pretrained = "laion400m_e32"  # Well-balanced pretraining dataset
    device = "cuda" if torch.cuda.is_available() else "cpu"

    model, _, preprocess = open_clip.create_model_and_transforms(
        model_name, pretrained=pretrained, device=device
    )

    # Common categories for image classification
    categories = [
        "person",
        "people",
        "portrait",
        "face",
        "selfie",
        "nature",
        "landscape",
        "forest",
        "mountains",
        "beach",
        "ocean",
        "water",
        "city",
        "urban",
        "building",
        "architecture",
        "skyline",
        "animal",
        "pet",
        "dog",
        "cat",
        "bird",
        "wildlife",
        "food",
        "meal",
        "dish",
        "restaurant",
        "cooking",
        "car",
        "vehicle",
        "transportation",
        "travel",
        "art",
        "painting",
        "drawing",
        "sketch",
        "illustration",
        "document",
        "text",
        "screenshot",
        "diagram",
        "chart",
        "graph",
        "technology",
        "computer",
        "phone",
        "device",
        "flower",
        "plant",
        "garden",
        "interior",
        "room",
        "furniture",
        "night",
        "sunset",
        "sunrise",
        "sky",
        "clouds",
        "sport",
        "game",
        "event",
        "concert",
        "festival",
        "abstract",
        "pattern",
        "texture",
        "design",
        "logo",
        "icon",
    ]

    # More detailed descriptive prompts for richer image description
    descriptive_prompts = [
        "a photo of {}",
        "a clear picture of {}",
        "a photograph of {}",
        "a detailed picture of {}",
        "a bright picture of {}",
        "a close-up photo of {}",
        "a beautiful image of {}",
        "{} in daylight",
        "{} in detail",
    ]

    # Attributes for richer description
    attributes = [
        "colorful",
        "bright",
        "dark",
        "vibrant",
        "detailed",
        "blurry",
        "sharp",
        "vintage",
        "modern",
        "retro",
        "elegant",
        "professional",
        "casual",
        "indoor",
        "outdoor",
        "natural",
        "artificial",
        "sunny",
        "cloudy",
        "rainy",
        "small",
        "large",
        "old",
        "new",
        "happy",
        "serious",
        "playful",
    ]

    # Activities for better context
    activities = [
        "sitting",
        "standing",
        "walking",
        "running",
        "jumping",
        "flying",
        "swimming",
        "eating",
        "drinking",
        "playing",
        "working",
        "relaxing",
        "performing",
        "dancing",
        "singing",
        "reading",
        "writing",
        "typing",
        "driving",
        "riding",
        "cooking",
        "building",
        "growing",
        "flowing",
    ]

    # Styles for artistic content
    styles = [
        "realistic",
        "abstract",
        "cartoon",
        "digital art",
        "painting",
        "sketch",
        "watercolor",
        "oil painting",
        "photograph",
        "3D render",
        "illustration",
        "minimalist",
        "surreal",
        "impressionist",
        "expressionist",
        "pop art",
    ]

    # Locations for context
    locations = [
        "indoors",
        "outdoors",
        "in a room",
        "in a house",
        "in an office",
        "in a park",
        "in a forest",
        "on a beach",
        "in the mountains",
        "in a city",
        "in a rural area",
        "in a studio",
        "in a garden",
        "on a street",
        "in a field",
        "by a lake",
        "by the ocean",
        "at home",
        "at work",
        "at a restaurant",
        "at an event",
    ]

    # Colors for visual description
    colors = [
        "red",
        "blue",
        "green",
        "yellow",
        "orange",
        "purple",
        "pink",
        "brown",
        "black",
        "white",
        "gray",
        "teal",
        "navy",
        "maroon",
        "gold",
        "silver",
        "multicolored",
        "pastel",
        "dark",
        "light",
        "bright",
        "muted",
    ]

    # Create consolidated lists for CLIP
    content_descriptions = categories.copy()

    # Add descriptive combinations
    for category in categories:
        # Add some random attributes to categories
        for attribute in random.sample(attributes, 3):
            content_descriptions.append(f"{attribute} {category}")
        # Add some activities where appropriate
        if category in ["person", "people", "dog", "cat", "bird", "animal", "pet"]:
            for activity in random.sample(activities, 3):
                content_descriptions.append(f"{category} {activity}")
        # Add some locations
        for location in random.sample(locations, 2):
            content_descriptions.append(f"{category} {location}")
        # Add some colors
        for color in random.sample(colors, 2):
            content_descriptions.append(f"{color} {category}")

    # Add style descriptions for visual content
    for style in styles:
        content_descriptions.append(style)
        content_descriptions.append(f"{style} image")

    # Create text tokens for all descriptions, using varied prompts
    all_text_prompts = []
    for desc in content_descriptions:
        # Choose a random descriptive prompt format
        prompt_template = random.choice(descriptive_prompts)
        all_text_prompts.append(prompt_template.format(desc))

    # Create CLIP text embeddings
    text_tokens = open_clip.tokenize(all_text_prompts).to(device)
    with torch.no_grad():
        text_features = model.encode_text(text_tokens)
        text_features /= text_features.norm(dim=-1, keepdim=True)

    logging.info(
        f"CLIP model {model_name} loaded successfully on {device} with {len(all_text_prompts)} descriptive prompts"
    )
    MODEL_LOADED = True
except Exception as e:
    logging.error(f"Failed to load CLIP model: {e}")
    MODEL_LOADED = False


def analyze_image(image_content):
    """
    Analyzes an image using CLIP and returns a detailed, human-like description.

    Args:
        image_content: Binary content of the image

    Returns:
        Dict with description and top categories
    """
    if not MODEL_LOADED:
        logging.warning("CLIP model not loaded, using fallback analysis")
        return {"description": "Unknown image content", "categories": ["Photos"]}

    try:
        # Load and preprocess the image
        image = Image.open(io.BytesIO(image_content))
        image_input = preprocess(image).unsqueeze(0).to(device)

        # Get image dimensions and orientation
        width, height = image.size
        orientation = (
            "portrait"
            if height > width
            else "landscape" if width > height else "square"
        )

        # Get dominant colors
        image_small = image.resize((50, 50))
        dom_colors = image_small.getcolors(2500)
        dom_colors = sorted(dom_colors, key=lambda x: x[0], reverse=True)
        color_names = ["dark", "light", "colorful", "vibrant", "muted", "bright"]

        # Generate image features
        with torch.no_grad():
            image_features = model.encode_image(image_input)
            image_features /= image_features.norm(dim=-1, keepdim=True)

            # Get similarity scores for all descriptive prompts
            similarity = (100.0 * image_features @ text_features.T).softmax(dim=-1)

            # Get top 15 matches for detailed description
            values, indices = similarity[0].topk(15)
            top_matches = [all_text_prompts[idx] for idx in indices]
            scores = values.tolist()

            # Extract key elements from the matches
            categories_found = []
            attributes_found = []
            activities_found = []
            styles_found = []
            locations_found = []
            colors_found = []

            for match in top_matches:
                # Process matches to extract key descriptors
                match_clean = (
                    match.replace("a photo of ", "")
                    .replace("a picture of ", "")
                    .replace("an image of ", "")
                )
                match_clean = match_clean.replace("a clear picture of ", "").replace(
                    "a photograph of ", ""
                )
                match_clean = match_clean.replace("a detailed picture of ", "").replace(
                    "a bright picture of ", ""
                )
                match_clean = match_clean.replace("a close-up photo of ", "").replace(
                    "a beautiful image of ", ""
                )
                match_clean = match_clean.replace(" in daylight", "").replace(
                    " in detail", ""
                )

                # Categorize elements
                found_category = False
                for category in categories:
                    if category in match_clean:
                        categories_found.append(category)
                        found_category = True
                        break

                for attribute in attributes:
                    if attribute in match_clean:
                        attributes_found.append(attribute)

                for activity in activities:
                    if activity in match_clean:
                        activities_found.append(activity)

                for style in styles:
                    if style in match_clean:
                        styles_found.append(style)

                for location in locations:
                    if location in match_clean:
                        locations_found.append(location)

                for color in colors:
                    if color in match_clean:
                        colors_found.append(color)

                if not found_category and match_clean not in categories_found:
                    categories_found.append(match_clean)

            # Deduplicate findings
            categories_found = list(dict.fromkeys(categories_found))[:3]
            attributes_found = list(dict.fromkeys(attributes_found))[:2]
            activities_found = list(dict.fromkeys(activities_found))[:1]
            styles_found = list(dict.fromkeys(styles_found))[:1]
            locations_found = list(dict.fromkeys(locations_found))[:1]
            colors_found = list(dict.fromkeys(colors_found))[:2]

            # Combine into a natural language description
            description_elements = []

            # Start with style if available (for artistic content)
            if styles_found:
                description_elements.append(f"{styles_found[0]}")

            # Add colors and attributes
            color_attr = []
            if colors_found:
                color_attr.extend(colors_found)
            if attributes_found:
                color_attr.extend(attributes_found)

            if color_attr:
                description_elements.append(f"{', '.join(color_attr)}")

            # Add the main subject
            if categories_found:
                description_elements.append(f"{categories_found[0]}")

            # Add activity if available
            if activities_found:
                description_elements.append(f"{activities_found[0]}")

            # Add location if available
            if locations_found:
                description_elements.append(f"{locations_found[0]}")

            # Add secondary elements if available
            if len(categories_found) > 1:
                description_elements.append(f"with {categories_found[1]}")

            # Combine all elements
            description = " ".join(description_elements)

            # Add image orientation and quality information
            description += f". {orientation.capitalize()} orientation"

            # Format the description to be more natural
            description = description.replace(" ,", ",")
            description = description.capitalize()

            # Create final result with top categories for categorization
            simplified_categories = [c for c in categories_found if c in categories]
            if not simplified_categories and categories_found:
                simplified_categories = categories_found

            result = {
                "description": description,
                "categories": simplified_categories[:5],
                "attributes": attributes_found,
                "colors": colors_found,
                "style": styles_found[0] if styles_found else None,
                "scores": dict(zip(top_matches[:5], scores[:5])),
                "orientation": orientation,
            }

            return result

    except Exception as e:
        logging.error(f"Error analyzing image: {e}")
        return {"description": "Error analyzing image", "categories": ["Photos"]}


def get_suggested_path_from_analysis(analysis, filename):
    """
    Suggests a file path based on image analysis results.

    Args:
        analysis: The result from analyze_image
        filename: Original filename for fallback

    Returns:
        Suggested path string
    """
    # If no valid analysis, use filename
    if not analysis or "categories" not in analysis or not analysis["categories"]:
        return None

    # Try to extract meaningful content from the description
    if "description" in analysis and analysis["description"]:
        # Get best path based on the main category but informed by the detailed description
        main_category = (
            analysis["categories"][0].title() if analysis["categories"] else None
        )
        description = analysis["description"]

        # Map certain categories to better folder names
        category_mapping = {
            "Person": "People",
            "People": "People",
            "Portrait": "People/Portraits",
            "Face": "People/Portraits",
            "Selfie": "People/Selfies",
            "Nature": "Nature",
            "Landscape": "Nature/Landscapes",
            "Forest": "Nature/Forests",
            "Mountains": "Nature/Mountains",
            "Beach": "Nature/Beaches",
            "Ocean": "Nature/Ocean",
            "Water": "Nature/Water",
            "City": "Places/Cities",
            "Urban": "Places/Urban",
            "Building": "Places/Buildings",
            "Architecture": "Places/Architecture",
            "Skyline": "Places/Skylines",
            "Animal": "Animals",
            "Pet": "Animals/Pets",
            "Dog": "Animals/Dogs",
            "Cat": "Animals/Cats",
            "Bird": "Animals/Birds",
            "Wildlife": "Animals/Wildlife",
            "Food": "Food",
            "Meal": "Food",
            "Dish": "Food",
            "Restaurant": "Food/Restaurants",
            "Cooking": "Food/Cooking",
            "Car": "Vehicles/Cars",
            "Vehicle": "Vehicles",
            "Transportation": "Vehicles",
            "Travel": "Travel",
            "Art": "Art",
            "Painting": "Art/Paintings",
            "Drawing": "Art/Drawings",
            "Sketch": "Art/Sketches",
            "Illustration": "Art/Illustrations",
            "Document": "Documents",
            "Text": "Documents",
            "Screenshot": "Screenshots",
            "Diagram": "Diagrams",
            "Chart": "Charts",
            "Graph": "Charts",
            "Technology": "Technology",
            "Computer": "Technology/Computers",
            "Phone": "Technology/Phones",
            "Device": "Technology/Devices",
            "Flower": "Nature/Flowers",
            "Plant": "Nature/Plants",
            "Garden": "Nature/Gardens",
            "Interior": "Interiors",
            "Room": "Interiors/Rooms",
            "Furniture": "Interiors/Furniture",
            "Night": "Nature/Night",
            "Sunset": "Nature/Sunsets",
            "Sunrise": "Nature/Sunrises",
            "Sky": "Nature/Sky",
            "Clouds": "Nature/Sky",
            "Sport": "Sports",
            "Game": "Entertainment/Games",
            "Event": "Events",
            "Concert": "Events/Concerts",
            "Festival": "Events/Festivals",
            "Abstract": "Abstract",
            "Pattern": "Abstract/Patterns",
            "Texture": "Abstract/Textures",
            "Design": "Design",
            "Logo": "Design/Logos",
            "Icon": "Design/Icons",
        }

        # Get mapped category or use the original
        if main_category:
            mapped_category = category_mapping.get(main_category, main_category)
        else:
            # Extract a meaningful term from the description if no main category
            words = description.lower().split()
            for word in words:
                word = word.capitalize()
                if word in category_mapping:
                    mapped_category = category_mapping[word]
                    break
            else:
                # If no recognized category, use a sensible default
                mapped_category = "Photos/General"

        return mapped_category

    # Fallback to simpler category-based approach
    top_category = (
        analysis["categories"][0].title() if analysis["categories"] else "Photo"
    )
    category_mapping = {
        "Person": "People",
        "People": "People",
        "Portrait": "People/Portraits",
        "Face": "People/Portraits",
        "Selfie": "People/Selfies",
        "Nature": "Nature",
        "Landscape": "Nature/Landscapes",
        "Forest": "Nature/Forests",
        "Mountains": "Nature/Mountains",
        "Beach": "Nature/Beaches",
        "Ocean": "Nature/Ocean",
        "Water": "Nature/Water",
        "City": "Places/Cities",
        "Urban": "Places/Urban",
        "Building": "Places/Buildings",
        "Architecture": "Places/Architecture",
        "Skyline": "Places/Skylines",
        "Animal": "Animals",
        "Pet": "Animals/Pets",
        "Dog": "Animals/Dogs",
        "Cat": "Animals/Cats",
        "Bird": "Animals/Birds",
        "Wildlife": "Animals/Wildlife",
        "Food": "Food",
        "Meal": "Food",
        "Dish": "Food",
        "Restaurant": "Food/Restaurants",
        "Cooking": "Food/Cooking",
        "Car": "Vehicles/Cars",
        "Vehicle": "Vehicles",
        "Transportation": "Vehicles",
        "Travel": "Travel",
        "Art": "Art",
        "Painting": "Art/Paintings",
        "Drawing": "Art/Drawings",
        "Sketch": "Art/Sketches",
        "Illustration": "Art/Illustrations",
        "Document": "Documents",
        "Text": "Documents",
        "Screenshot": "Screenshots",
        "Diagram": "Diagrams",
        "Chart": "Charts",
        "Graph": "Charts",
        "Technology": "Technology",
        "Computer": "Technology/Computers",
        "Phone": "Technology/Phones",
        "Device": "Technology/Devices",
        "Flower": "Nature/Flowers",
        "Plant": "Nature/Plants",
        "Garden": "Nature/Gardens",
        "Interior": "Interiors",
        "Room": "Interiors/Rooms",
        "Furniture": "Interiors/Furniture",
        "Night": "Nature/Night",
        "Sunset": "Nature/Sunsets",
        "Sunrise": "Nature/Sunrises",
        "Sky": "Nature/Sky",
        "Clouds": "Nature/Sky",
        "Sport": "Sports",
        "Game": "Entertainment/Games",
        "Event": "Events",
        "Concert": "Events/Concerts",
        "Festival": "Events/Festivals",
        "Abstract": "Abstract",
        "Pattern": "Abstract/Patterns",
        "Texture": "Abstract/Textures",
        "Design": "Design",
        "Logo": "Design/Logos",
        "Icon": "Design/Icons",
    }

    # Get mapped category or use the original
    mapped_category = category_mapping.get(top_category, top_category)

    return mapped_category
